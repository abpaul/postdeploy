import { Client, StreamableHTTPClientTransport } from "@modelcontextprotocol/client";

const MCP_URL = required("MCP_URL");
const OAUTH_ACCESS_TOKEN = required("MCP_OAUTH_ACCESS_TOKEN");
const PROJECT_HANDLE = required("MCP_PROJECT_HANDLE");
const MODERN_VERSION = "2026-07-28";
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

function domainCode(result) {
  return contentJson(result)?.error?.code;
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

function client() {
  const c = new Client(
    { name: "alplus-mcp-rate-limit", version: "1.0.0" },
    { versionNegotiation: { mode: { pin: MODERN_VERSION } } },
  );
  const transport = new StreamableHTTPClientTransport(new URL(MCP_URL), {
    authProvider: { token: async () => OAUTH_ACCESS_TOKEN },
  });
  return { client: c, transport };
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function main() {
  console.log("--- AL+ MCP weighted rate limit ---");
  const light = client();
  try {
    await light.client.connect(light.transport);
    const lightResults = await Promise.all(
      Array.from({ length: 20 }, (_, offset) =>
        light.client.callTool({
          name: "actions.read",
          arguments: { action: "projects.list", arguments: { limit: 1 } },
        }).then((result) => ({ index: offset + 1, result })),
      ),
    );
    let lightAllowed = 0;
    for (const { index, result } of lightResults) {
      check(`light read request ${index} is allowed`, result.isError !== true, detail(result));
      if (result.isError !== true) lightAllowed += 1;
    }
    check("light tool permits twenty requests", lightAllowed === 20, `allowed=${lightAllowed}`);
    const lightRefusal = await light.client.callTool({
      name: "actions.read",
      arguments: { action: "projects.list", arguments: { limit: 1 } },
    });
    check(
      "21st light read is rate_limited",
      lightRefusal.isError === true && domainCode(lightRefusal) === "rate_limited",
      detail(lightRefusal),
    );
  } finally {
    await light.client.close().catch(() => undefined);
    await light.transport.close().catch(() => undefined);
  }

  await sleep(1100);

  const heavy = client();
  try {
    await heavy.client.connect(heavy.transport);
    const runId = Date.now();
    const heavyResults = await Promise.all(
      Array.from({ length: 10 }, (_, offset) => {
        const index = offset + 1;
        return heavy.client.callTool({
          name: "actions.write",
          arguments: {
            action: "changelog.upsert_draft",
            arguments: {
              project_handle: PROJECT_HANDLE,
              external_id: `rate-heavy-${runId}-${index}`,
              markdown: `---\ntitle: Rate heavy ${index}\n---\nRate limit proof.`,
              sources: [{ kind: "other", url: "https://example.com/rate-limit" }],
            },
            idempotency_key: `rate-heavy-${runId}-${index}`,
          },
        }).then((result) => ({ index, result }));
      }),
    );
    let heavyAllowed = 0;
    for (const { index, result } of heavyResults) {
      check(`heavy mutation request ${index} is allowed`, result.isError !== true, detail(result));
      if (result.isError !== true) heavyAllowed += 1;
    }
    check("heavy tool permits ten requests", heavyAllowed === 10, `allowed=${heavyAllowed}`);
    const heavyRefusal = await heavy.client.callTool({
      name: "actions.write",
      arguments: {
        action: "changelog.upsert_draft",
        arguments: {
          project_handle: PROJECT_HANDLE,
          external_id: `rate-heavy-${runId}-11`,
          markdown: "---\ntitle: Rate heavy 11\n---\nRate limit proof.",
          sources: [{ kind: "other", url: "https://example.com/rate-limit" }],
        },
        idempotency_key: `rate-heavy-${runId}-11`,
      },
    });
    check(
      "11th heavy mutation is rate_limited",
      heavyRefusal.isError === true && domainCode(heavyRefusal) === "rate_limited",
      detail(heavyRefusal),
    );
  } finally {
    await heavy.client.close().catch(() => undefined);
    await heavy.transport.close().catch(() => undefined);
  }

  console.log(`RESULT: ${passed} passed, ${failed} failed`);
  if (failed > 0) process.exitCode = 1;
}

main().catch((error) => {
  console.error(`mcp-rate-limit: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
});
