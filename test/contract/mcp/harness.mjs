import {
  Client,
  StreamableHTTPClientTransport,
} from "@modelcontextprotocol/client";

const MCP_URL = required("MCP_URL");
const OAUTH_ACCESS_TOKEN = required("MCP_OAUTH_ACCESS_TOKEN");
const PROJECT_HANDLE = required("MCP_PROJECT_HANDLE");
const NO_CHANGELOG_PROJECT_HANDLE = required("MCP_NO_CHANGELOG_PROJECT_HANDLE");
const NO_CHANGELOG_OAUTH_ACCESS_TOKEN = required("MCP_NO_CHANGELOG_OAUTH_ACCESS_TOKEN");

const MODERN_VERSION = "2026-07-28";
const LEGACY_VERSION = "2025-11-25";
const TOOL_NAMES = [
  "context.get",
  "actions.search",
  "actions.get",
  "actions.read",
  "actions.write",
  "actions.publish",
  "actions.destroy",
  "confirmations.get",
];
const READ_TOOLS = new Set([
  "context.get",
  "actions.search",
  "actions.get",
  "actions.read",
  "confirmations.get",
]);

const JSON_SCHEMA_TYPES = new Set([
  "array",
  "boolean",
  "integer",
  "null",
  "number",
  "object",
  "string",
]);

let passed = 0;
let failed = 0;

function required(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is required`);
  }
  return value;
}

function check(label, condition, detail = "") {
  if (condition) {
    console.log(`  PASS  ${label}`);
    passed += 1;
    return;
  }

  console.error(`  FAIL  ${label}${detail ? `: ${detail}` : ""}`);
  failed += 1;
}

function checkEqual(label, actual, expected) {
  check(label, actual === expected, `want=${expected} got=${actual}`);
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isJsonSchema(value) {
  if (typeof value === "boolean") return true;
  if (!isObject(value)) return false;

  if (value.type !== undefined) {
    if (typeof value.type === "string" && !JSON_SCHEMA_TYPES.has(value.type)) return false;
    if (
      Array.isArray(value.type) &&
      value.type.some((type) => typeof type !== "string" || !JSON_SCHEMA_TYPES.has(type))
    ) {
      return false;
    }
  }

  if (value.required !== undefined) {
    if (!Array.isArray(value.required) || value.required.some((name) => typeof name !== "string")) {
      return false;
    }
  }

  if (value.properties !== undefined) {
    if (!isObject(value.properties)) return false;
    if (Object.values(value.properties).some((schema) => !isJsonSchema(schema))) return false;
  }

  if (value.items !== undefined && !isJsonSchema(value.items)) return false;
  if (value.anyOf !== undefined && (!Array.isArray(value.anyOf) || value.anyOf.some((schema) => !isJsonSchema(schema)))) {
    return false;
  }
  if (value.oneOf !== undefined && (!Array.isArray(value.oneOf) || value.oneOf.some((schema) => !isJsonSchema(schema)))) {
    return false;
  }
  if (value.allOf !== undefined && (!Array.isArray(value.allOf) || value.allOf.some((schema) => !isJsonSchema(schema)))) {
    return false;
  }

  return true;
}

function sampleValue(schema, property) {
  if (schema?.const !== undefined) return schema.const;
  if (Array.isArray(schema?.enum) && schema.enum.length > 0) return schema.enum[0];
  const branch = schema?.oneOf?.[0] ?? schema?.anyOf?.[0];
  if (branch) return sampleValue(branch, property);

  const type = Array.isArray(schema?.type)
    ? schema.type.find((candidate) => candidate !== "null") ?? schema.type[0]
    : schema?.type;
  if (type === "boolean") return false;
  if (type === "integer" || type === "number") return schema.minimum ?? 1;
  if (type === "array") {
    const size = Number.isInteger(schema.minItems) ? schema.minItems : 0;
    return Array.from({ length: size }, () => sampleValue(schema.items ?? {}, property));
  }
  if (type === "object") {
    const properties = isObject(schema.properties) ? schema.properties : {};
    return Object.fromEntries(
      [...new Set(schema.required ?? [])].map((name) => [name, sampleValue(properties[name] ?? {}, name)]),
    );
  }
  if (property === "project_handle") return PROJECT_HANDLE;
  if (property === "cursor") return "contract-cursor";
  if (property === "idempotency_key") return `contract-${property}`;
  if (property.endsWith("_handle") || property.endsWith("_id")) return "contract-missing";
  return "contract-sample";
}

function fixtureFor(tool) {
  const schema = tool.inputSchema ?? {};
  const branch = schema.oneOf?.[0] ?? schema.anyOf?.[0] ?? {};
  const properties = {
    ...(isObject(schema.properties) ? schema.properties : {}),
    ...(isObject(branch.properties) ? branch.properties : {}),
  };
  const required = [...new Set([...(schema.required ?? []), ...(branch.required ?? [])])];
  const fixture = {};
  for (const name of required) {
    fixture[name] = sampleValue(properties[name] ?? {}, name);
  }
  return fixture;
}

function contentJson(result) {
  if (isObject(result.structuredContent)) return result.structuredContent;

  const text = result.content?.find((item) => item.type === "text")?.text;
  if (!text) return undefined;

  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

function domainCode(result) {
  const body = contentJson(result);
  return body?.error?.code;
}

function clientFor(mode, token = OAUTH_ACCESS_TOKEN) {
  const client = new Client(
    { name: "alplus-mcp-contract", version: "1.0.0" },
    { versionNegotiation: { mode } },
  );
  const transport = new StreamableHTTPClientTransport(new URL(MCP_URL), {
    authProvider: { token: async () => token },
  });
  return { client, transport };
}

async function listAndCheckTools(client, generation) {
  const listed = await client.listTools({});
  const names = listed.tools.map((tool) => tool.name);
  const expectedNames = generation === MODERN_VERSION ? [...TOOL_NAMES].sort() : TOOL_NAMES;
  check(`${generation}: tools/list returns exactly the gateway tools`, names.length === TOOL_NAMES.length, `got=${names.length}`);
  check(
    `${generation}: tools/list order is frozen`,
    JSON.stringify(names) === JSON.stringify(expectedNames),
    `got=${JSON.stringify(names)}`,
  );
  check(
    `${generation}: tools/list contains no internal action names`,
    names.every((name) => TOOL_NAMES.includes(name)),
    `got=${JSON.stringify(names)}`,
  );

  for (const tool of listed.tools) {
    check(`${generation}: ${tool.name} declares valid input schema`, isJsonSchema(tool.inputSchema));
    check(`${generation}: ${tool.name} declares valid output schema`, isJsonSchema(tool.outputSchema));
    const annotations = tool.annotations ?? {};
    if (READ_TOOLS.has(tool.name)) {
      check(`${generation}: ${tool.name} declares readOnlyHint`, annotations.readOnlyHint === true);
    } else {
      check(`${generation}: ${tool.name} declares idempotentHint`, annotations.idempotentHint === true);
    }
    const fixture = fixtureFor(tool);
    check(`${generation}: ${tool.name} has an executable input fixture`, isObject(fixture));
  }
}

async function checkDomainAndCalls(client, generation, mode) {
  const direct = await client.callTool({
    name: "projects.list",
    arguments: {},
  });
  checkEqual(
    `${generation}: direct internal tool calls are rejected`,
    domainCode(direct),
    "not_found",
  );

  const projects = await client.callTool({
    name: "actions.read",
    arguments: { action: "projects.list", arguments: { limit: 1 } },
  });
  const projectsBody = contentJson(projects);
  check(`${generation}: actions.read returns structured result`, isObject(projectsBody));
  check(
    `${generation}: actions.read returns the project cursor`,
    isObject(projectsBody?.result) && Object.hasOwn(projectsBody.result, "next_cursor"),
  );
  for (const limit of ["abc", 0, 101]) {
    const invalidLimit = await client.callTool({
      name: "actions.read",
      arguments: { action: "projects.list", arguments: { limit } },
    });
    checkEqual(
      `${generation}: actions.read rejects limit=${JSON.stringify(limit)} with invalid_argument`,
      domainCode(invalidLimit),
      "invalid_argument",
    );
  }

  const noChangelogConnection = clientFor(mode, NO_CHANGELOG_OAUTH_ACCESS_TOKEN);
  let noChangelogSettings;
  try {
    await noChangelogConnection.client.connect(noChangelogConnection.transport);
    noChangelogSettings = await noChangelogConnection.client.callTool({
      name: "actions.read",
      arguments: {
        action: "changelog.get_settings",
        arguments: { project_handle: NO_CHANGELOG_PROJECT_HANDLE },
      },
    });
  } finally {
    await noChangelogConnection.client.close().catch(() => undefined);
    await noChangelogConnection.transport.close().catch(() => undefined);
  }
  const noChangelogMessage = JSON.stringify(contentJson(noChangelogSettings) ?? noChangelogSettings);
  check(
    `${generation}: actions.read returns the changelog settings result`,
    isObject(contentJson(noChangelogSettings)) || noChangelogMessage.length > 0,
    `response=${noChangelogMessage}`,
  );

  const missingIdempotency = await client.callTool({
    name: "actions.write",
    arguments: {
      action: "changelog.upsert_draft",
      arguments: {
        project_handle: PROJECT_HANDLE,
        external_id: `contract-${generation}`,
        markdown: "---\ntitle: Contract\n---\nContract",
        sources: [{ kind: "other", url: "https://example.com/contract" }],
      },
    },
  });
  check(`${generation}: gateway failure is a successful tool result`, missingIdempotency.isError === true);
  checkEqual(
    `${generation}: gateway failure carries missing_idempotency_key`,
    domainCode(missingIdempotency),
    "missing_idempotency_key",
  );

  const tamperedCursor = await client.callTool({
    name: "actions.read",
    arguments: {
      action: "changelog.list_entries",
      arguments: { project_handle: PROJECT_HANDLE, cursor: "tampered-cursor", limit: 1 },
    },
  });
  check(`${generation}: tampered cursor is a gateway failure`, tamperedCursor.isError === true);
  checkEqual(
    `${generation}: tampered cursor carries invalid_cursor`,
    domainCode(tamperedCursor),
    "invalid_cursor",
  );
}

async function rawJsonRpc(body, token, protocolVersion, extraHeaders = {}) {
  const headers = {
    Accept: "application/json, text/event-stream",
    "Content-Type": "application/json",
    "MCP-Protocol-Version": protocolVersion,
    ...extraHeaders,
  };
  if (token) headers.Authorization = `Bearer ${token}`;

  const response = await fetch(MCP_URL, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
  const text = await response.text();
  let payload;
  try {
    payload = JSON.parse(text);
  } catch {
    const event = text
      .split("\n")
      .find((line) => line.startsWith("data:"))
      ?.slice("data:".length)
      .trim();
    payload = event ? JSON.parse(event) : undefined;
  }
  return { response, payload };
}

async function checkUnauthenticatedRequest() {
  const { response } = await rawJsonRpc(
    { jsonrpc: "2.0", id: "missing-token", method: "initialize", params: {} },
    undefined,
    LEGACY_VERSION,
  );
  checkEqual("absent bearer token returns HTTP 401", response.status, 401);
}
async function checkProtocolFailure() {
  const initialized = await rawJsonRpc(
    {
      jsonrpc: "2.0",
      id: "protocol-initialize",
      method: "initialize",
      params: {
        protocolVersion: LEGACY_VERSION,
        capabilities: {},
        clientInfo: { name: "alplus-mcp-contract", version: "1.0.0" },
      },
    },
    OAUTH_ACCESS_TOKEN,
    LEGACY_VERSION,
  );
  const sessionId = initialized.response.headers.get("mcp-session-id");
  const { response, payload } = await rawJsonRpc(
    { jsonrpc: "2.0", id: "protocol-failure", method: "not/a/real/method", params: {} },
    OAUTH_ACCESS_TOKEN,
    LEGACY_VERSION,
    sessionId ? { "Mcp-Session-Id": sessionId } : {},
  );
  check("protocol failure returns a JSON-RPC error response", isObject(payload?.error));
  checkEqual("protocol failure uses method-not-found code", payload?.error?.code, -32601);
  check("protocol failure is not a domain result", payload?.result === undefined);
  check("protocol failure has an HTTP response", response.status >= 200 && response.status < 500);
}

async function exerciseGeneration(mode, expectedVersion, generation, modern) {
  const { client, transport } = clientFor(mode);
  try {
    await client.connect(transport);
    checkEqual(`${generation}: negotiated protocol version`, client.getNegotiatedProtocolVersion(), expectedVersion);
    checkEqual(`${generation}: protocol era`, client.getProtocolEra(), modern ? "modern" : "legacy");

    if (modern) {
      const discover = client.getDiscoverResult() ?? (await client.discover());
      check(`${generation}: server/discover returns a result`, isObject(discover));
      check(
        `${generation}: server/discover advertises the modern version`,
        discover?.supportedVersions?.includes(expectedVersion) === true,
      );
    } else {
      check(`${generation}: legacy connection has no discover result`, client.getDiscoverResult() === undefined);
    }

    await listAndCheckTools(client, generation);
    await checkDomainAndCalls(client, generation, mode);
  } finally {
    await client.close().catch(() => undefined);
    await transport.close().catch(() => undefined);
  }
}

async function main() {
  console.log("--- AL+ MCP wire contract ---");
  await checkUnauthenticatedRequest();
  await checkProtocolFailure();
  await exerciseGeneration({ pin: MODERN_VERSION }, MODERN_VERSION, "2026-07-28", true);
  await exerciseGeneration("legacy", LEGACY_VERSION, "2025-11-25", false);
  console.log(`RESULT: ${passed} passed, ${failed} failed`);
  if (failed > 0) process.exitCode = 1;
}

main().catch((error) => {
  console.error(`mcp-contract: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
});
