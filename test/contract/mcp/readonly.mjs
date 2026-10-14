import { Client, StreamableHTTPClientTransport } from "@modelcontextprotocol/client";

const MCP_URL = required("MCP_URL");
const OAUTH_ACCESS_TOKEN = required("MCP_OAUTH_ACCESS_TOKEN");
const MODERN_VERSION = "2026-07-28";
const GATEWAY_TOOLS = [
  "actions.destroy",
  "actions.get",
  "actions.publish",
  "actions.read",
  "actions.search",
  "actions.write",
  "confirmations.get",
  "context.get",
];
let passed = 0;
let failed = 0;

function required(name) {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}
function object(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
function contentJson(result) {
  if (object(result?.structuredContent)) return result.structuredContent;
  const text = result?.content?.find((item) => item.type === "text")?.text;
  if (!text) return undefined;
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}
function check(label, condition, detail = "") {
  if (condition) {
    console.log(`  PASS  ${label}`);
    passed += 1;
  } else {
    console.error(`  FAIL  ${label}${detail ? `: ${detail}` : ""}`);
    failed += 1;
  }
}
function detail(result) {
  return JSON.stringify(contentJson(result) ?? result);
}
function code(result) {
  return contentJson(result)?.error?.code;
}

async function expectAllowed(client, label, request) {
  const result = await client.callTool(request);
  check(`${label} returns a tool result`, object(result), detail(result));
  check(`${label} is allowed`, result.isError !== true, detail(result));
}

async function expectInsufficientScope(client, label, request) {
  const result = await client.callTool(request);
  check(`${label} returns a tool result`, object(result), detail(result));
  check(`${label} is refused`, result.isError === true, detail(result));
  check(`${label} reports insufficient_scope`, code(result) === "insufficient_scope", detail(result));
}

async function main() {
  console.log("--- AL+ MCP read-only grant ---");
  const client = new Client(
    { name: "alplus-mcp-readonly", version: "1.0.0" },
    { versionNegotiation: { mode: { pin: MODERN_VERSION } } },
  );
  const transport = new StreamableHTTPClientTransport(new URL(MCP_URL), {
    authProvider: { token: async () => OAUTH_ACCESS_TOKEN },
  });

  try {
    await client.connect(transport);
    const listed = await client.listTools({});
    const names = listed.tools.map((tool) => tool.name);
    check(
      "read-only connection sees the stable gateway catalog",
      JSON.stringify(names) === JSON.stringify(GATEWAY_TOOLS),
      `got=${JSON.stringify(names)}`,
    );

    await expectAllowed(client, "context.get", {
      name: "context.get",
      arguments: {},
    });
    await expectAllowed(client, "actions.search", {
      name: "actions.search",
      arguments: { intent: "publish changelog entry" },
    });
    await expectAllowed(client, "actions.read projects.list", {
      name: "actions.read",
      arguments: { action: "projects.list", arguments: { limit: 100 } },
    });
    await expectAllowed(client, "actions.read changelog.list_entries", {
      name: "actions.read",
      arguments: { action: "changelog.list_entries", arguments: { limit: 100 } },
    });

    await expectInsufficientScope(client, "actions.write", {
      name: "actions.write",
      arguments: {
        action: "changelog.upsert_draft",
        arguments: {
          external_id: "readonly-attempt",
          markdown: "---\ntitle: Read only\n---\nNo write",
          sources: [{ kind: "other", url: "https://example.com/readonly" }],
        },
        idempotency_key: "readonly-write",
      },
    });
    await expectInsufficientScope(client, "actions.publish", {
      name: "actions.publish",
      arguments: {
        action: "changelog.publish_entry",
        arguments: { entry_handle: "missing", expected_revision: 1 },
        idempotency_key: "readonly-publish",
      },
    });
    await expectInsufficientScope(client, "actions.destroy", {
      name: "actions.destroy",
      arguments: {
        action: "changelog.delete_entry",
        arguments: { entry_handle: "missing" },
        idempotency_key: "readonly-destroy",
      },
    });
  } finally {
    await client.close().catch(() => undefined);
    await transport.close().catch(() => undefined);
  }

  console.log(`RESULT: ${passed} passed, ${failed} failed`);
  if (failed > 0) process.exitCode = 1;
}

main().catch((error) => {
  console.error(`mcp-readonly: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
});
