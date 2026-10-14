import { Client, StreamableHTTPClientTransport } from "@modelcontextprotocol/client";

const MCP_URL = required("MCP_URL");
const OAUTH_ACCESS_TOKEN = required("MCP_OAUTH_ACCESS_TOKEN");
const PROJECT_HANDLE = required("MCP_PROJECT_HANDLE");
const SECOND_OAUTH_ACCESS_TOKEN = required("MCP_SECOND_OAUTH_ACCESS_TOKEN");
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
  let body;
  if (object(result?.structuredContent)) {
    body = result.structuredContent;
  } else {
    const text = result?.content?.find((item) => item.type === "text")?.text;
    if (!text) return undefined;
    try {
      body = JSON.parse(text);
    } catch {
      return undefined;
    }
  }
  return typeof body?.action === "string" && object(body?.result) ? body.result : body;
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
function checkEqual(label, actual, expected) {
  check(label, actual === expected, `want=${expected} got=${actual}`);
}

function resultDetail(result) {
  const body = contentJson(result);
  return body === undefined ? JSON.stringify(result) : JSON.stringify(body);
}
function domainCode(result) {
  return contentJson(result)?.error?.code;
}

const PUBLISH_ACTIONS = new Set([
  "changelog.publish_entry",
  "public.publish",
  "status.publish_announcement",
  "status.publish_incident_draft",
  "status.publish_update",
]);
const DESTRUCTIVE_ACTIONS = new Set([
  "changelog.delete_entry",
  "monitor.delete",
  "monitor.reissue_heartbeat_secret",
  "public.unpublish",
  "observe.delete_issue_comment",
  "observe.delete_issue_report",
]);


function gatewayCall(name, args) {
  if (name === "confirmations.get") return { name, arguments: args };
  const tool = DESTRUCTIVE_ACTIONS.has(name)
    ? "actions.destroy"
    : PUBLISH_ACTIONS.has(name)
      ? "actions.publish"
      : name === "actions.write"
        ? name
        : READ_ACTIONS.has(name)
          ? "actions.read"
          : "actions.write";
  const { idempotency_key, ...actionArguments } = args;
  const argumentsBody = { action: name, arguments: actionArguments };
  if (idempotency_key !== undefined) argumentsBody.idempotency_key = idempotency_key;
  return { name: tool, arguments: argumentsBody };
}

const READ_ACTIONS = new Set([
  "projects.list",
  "changelog.get_entry",
  "changelog.get_revision",
  "changelog.get_settings",
  "changelog.list_revisions",
  "changelog.preview_entry",
  "measure.list_sites",
  "monitor.get",
  "monitor.list",
  "confirmations.get",
]);
async function call(client, label, name, args) {
  let lastError;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const result = await client.callTool(gatewayCall(name, args));
      check(`${label} returns a tool result`, object(result), resultDetail(result));
      check(`${label} is not an error`, result.isError !== true, resultDetail(result));
      return result;
    } catch (error) {
      lastError = error;
    }
  }
  const detail = lastError instanceof Error ? lastError.message : String(lastError);
  check(`${label} returns a tool result`, false, detail);
  check(`${label} is not an error`, false, detail);
  return undefined;
}

async function publicRequest(path, expectedStatus, label, expectedText) {
  const url = new URL(path, MCP_URL);
  try {
    const response = await fetch(url, { redirect: "manual" });
    const body = await response.text();
    check(`${label} returns HTTP ${expectedStatus}`, response.status === expectedStatus, `got=${response.status}`);
    if (expectedText !== undefined) {
      check(`${label} contains the published entry`, body.includes(expectedText), `body does not contain ${expectedText}`);
    }
  } catch (error) {
    check(`${label} returns HTTP ${expectedStatus}`, false, error instanceof Error ? error.message : String(error));
  }
}
async function fetchPublic(path, label) {
  const url = new URL(path, MCP_URL);
  try {
    const response = await fetch(url, { redirect: "manual" });
    const body = await response.text();
    check(`${label} returns HTTP 200`, response.status === 200, `got=${response.status}`);
    return body;
  } catch (error) {
    check(`${label} returns HTTP 200`, false, error instanceof Error ? error.message : String(error));
    return undefined;
  }
}

async function main() {
  console.log("--- AL+ MCP agent lifecycle ---");
  const client = new Client(
    { name: "alplus-mcp-lifecycle", version: "1.0.0" },
    { versionNegotiation: { mode: { pin: MODERN_VERSION } } },
  );
  const transport = new StreamableHTTPClientTransport(new URL(MCP_URL), {
    authProvider: { token: async () => OAUTH_ACCESS_TOKEN },
  });
  const runId = Date.now().toString();
  const externalId = `mcp-lifecycle-${runId}`;
  const markdown = `---\ntitle: MCP lifecycle acceptance\n---\nA lifecycle entry from the wire acceptance test.`;
  let entry;
  let publicUrl;
  let entryPublicUrl;

  try {
    await client.connect(transport);
    check("modern client connects", client.getNegotiatedProtocolVersion() === MODERN_VERSION);

    const projects = await call(client, "projects.list", "projects.list", { limit: 100 });
    const projectsBody = contentJson(projects);
    check("projects.list includes the target project", projectsBody?.projects?.some((item) => item.name?.includes("MCP Contract")));

    const heartbeatCreate = await call(client, "create heartbeat monitor", "monitor.create", {
      project_handle: PROJECT_HANDLE,
      name: `MCP heartbeat ${runId}`,
      type: "heartbeat",
      interval_seconds: 300,
      grace_period_seconds: 60,
      idempotency_key: `lifecycle-heartbeat-create-${runId}`,
    });
    const heartbeatCreateBody = contentJson(heartbeatCreate);
    const heartbeatMonitor = heartbeatCreateBody?.monitor;
    const heartbeatSecret = heartbeatCreateBody?.heartbeat_secret;
    check("heartbeat create returns a setup secret", typeof heartbeatSecret === "string" && heartbeatSecret.startsWith("hb_"), resultDetail(heartbeatCreate));
    check("heartbeat create returns a monitor handle", typeof heartbeatMonitor?.handle === "string", resultDetail(heartbeatCreate));

    const heartbeatGet = await call(client, "read heartbeat monitor", "monitor.get", {
      project_handle: PROJECT_HANDLE,
      monitor_handle: heartbeatMonitor?.handle,
    });
    const heartbeatGetBody = contentJson(heartbeatGet);
    const heartbeatGetText = JSON.stringify(heartbeatGetBody) || "";
    check("heartbeat get omits the setup secret", !heartbeatSecret || !heartbeatGetText.includes(heartbeatSecret), resultDetail(heartbeatGet));
    check("heartbeat get omits the token hash", !heartbeatGetText.includes("heartbeat_token_hash"), resultDetail(heartbeatGet));

    const heartbeatList = await call(client, "list heartbeat monitors", "monitor.list", {
      project_handle: PROJECT_HANDLE,
      limit: 100,
    });
    const heartbeatListBody = contentJson(heartbeatList);
    const heartbeatListText = JSON.stringify(heartbeatListBody) || "";
    check("heartbeat list omits the setup secret", !heartbeatSecret || !heartbeatListText.includes(heartbeatSecret), resultDetail(heartbeatList));
    check("heartbeat list omits the token hash", !heartbeatListText.includes("heartbeat_token_hash"), resultDetail(heartbeatList));

    const heartbeatReissue = await call(client, "request heartbeat secret reissue", "monitor.reissue_heartbeat_secret", {
      project_handle: PROJECT_HANDLE,
      monitor_handle: heartbeatMonitor?.handle,
      idempotency_key: `lifecycle-heartbeat-reissue-${runId}`,
    });
    check(
      "heartbeat reissue waits for dashboard approval",
      contentJson(heartbeatReissue)?.status === "pending",
      resultDetail(heartbeatReissue),
    );

    if (heartbeatMonitor?.handle) {
      await call(client, "delete heartbeat monitor", "monitor.delete", {
        project_handle: PROJECT_HANDLE,
        monitor_handle: heartbeatMonitor.handle,
        idempotency_key: `lifecycle-heartbeat-delete-${runId}`,
      });
    }

    const upsertArgs = {
      project_handle: PROJECT_HANDLE,
      external_id: externalId,
      markdown,
      sources: [{ kind: "other", url: "https://example.com/mcp-lifecycle", label: "Lifecycle evidence" }],
      idempotency_key: `lifecycle-upsert-${runId}`,
    };
    const firstUpsert = await call(client, "upsert draft", "changelog.upsert_draft", upsertArgs);
    const firstBody = contentJson(firstUpsert);
    entry = firstBody?.entry;
    check("upsert draft stores a draft", entry?.status === "draft", resultDetail(firstUpsert));
    check("upsert draft returns an entry handle", typeof entry?.handle === "string", resultDetail(firstUpsert));

    const repeatedUpsert = await call(client, "repeat upsert with the same idempotency key", "changelog.upsert_draft", upsertArgs);
    check(
      "same idempotency key returns an identical result",
      JSON.stringify(contentJson(repeatedUpsert)) === JSON.stringify(firstBody),
      `first=${resultDetail(firstUpsert)} repeat=${resultDetail(repeatedUpsert)}`,
    );
    const entryHandle = entry?.handle;
    const secondClient = new Client(
      { name: "alplus-mcp-lifecycle-second", version: "1.0.0" },
      { versionNegotiation: { mode: { pin: MODERN_VERSION } } },
    );
    const secondTransport = new StreamableHTTPClientTransport(new URL(MCP_URL), {
      authProvider: { token: async () => SECOND_OAUTH_ACCESS_TOKEN },
    });
    let revised;
    try {
      await secondClient.connect(secondTransport);
      revised = await secondClient.callTool(
        gatewayCall("changelog.upsert_draft", {
          project_handle: PROJECT_HANDLE,
          entry_handle: entryHandle,
          external_id: externalId,
          markdown: "---\ntitle: MCP lifecycle acceptance\n---\nA lifecycle entry revised by a second client.",
          sources: [{ kind: "other", url: "https://example.com/mcp-lifecycle-revision", label: "Second client" }],
          idempotency_key: `lifecycle-cross-client-${runId}`,
        }),
      );
      const revisedEntry = contentJson(revised)?.entry;
      check(
        "upsert with entry_handle revises across clients",
        revisedEntry?.handle === entryHandle && revisedEntry?.status === "draft",
        resultDetail(revised),
      );
    } finally {
      await secondClient.close().catch(() => undefined);
      await secondTransport.close().catch(() => undefined);
    }


    const preview = await call(client, "preview draft", "changelog.preview_entry", {
      project_handle: PROJECT_HANDLE,
      entry_handle: entryHandle,
    });
    check("preview contains rendered lifecycle content", contentJson(preview)?.html?.includes("lifecycle entry"), resultDetail(preview));

    const revisions = await call(client, "list draft revisions", "changelog.list_revisions", {
      project_handle: PROJECT_HANDLE,
      entry_handle: entryHandle,
      limit: 100,
    });
    const revision = contentJson(revisions)?.revisions?.[0];
    check("cross-client revision remains readable", revision?.revision_number === 1, resultDetail(revisions));

    const published = await call(client, "publish draft", "changelog.publish_entry", {
      project_handle: PROJECT_HANDLE,
      entry_handle: entryHandle,
      expected_revision: revision?.revision_number,
      idempotency_key: `lifecycle-publish-${runId}`,
    });
    const publishedEntry = contentJson(published)?.entry;
    check("publish uses the expected revision", publishedEntry?.status === "published", resultDetail(published));
    const repeatedPublish = await client.callTool(
      gatewayCall("changelog.publish_entry", {
        project_handle: PROJECT_HANDLE,
        entry_handle: entryHandle,
        expected_revision: revision?.revision_number,
        idempotency_key: `lifecycle-repeat-publish-${runId}`,
      }),
    );
    checkEqual(
      "repeated publish returns already_published",
      domainCode(repeatedPublish),
      "already_published",
    );
    await call(client, "publish Public identity", "public.publish", {
      project_handle: PROJECT_HANDLE,
      idempotency_key: `lifecycle-public-publish-${runId}`,
    });


    const settings = await call(client, "read public settings", "changelog.get_settings", {
      project_handle: PROJECT_HANDLE,
    });
    publicUrl = contentJson(settings)?.settings?.public_url;
    check("published settings include a public URL", typeof publicUrl === "string", resultDetail(settings));
    entryPublicUrl = publicUrl && publishedEntry?.public_slug
      ? `${publicUrl}/${publishedEntry.public_slug}`
      : undefined;
    check("published entry includes an entry public URL", typeof entryPublicUrl === "string", resultDetail(published));
    if (publicUrl) await publicRequest(publicUrl, 200, "published changelog URL", "MCP lifecycle acceptance");
    if (entryPublicUrl) await publicRequest(entryPublicUrl, 200, "published entry URL", "MCP lifecycle acceptance");
    const publicHtml = publicUrl ? await fetchPublic(publicUrl, "public changelog HTML") : undefined;
    if (publicHtml !== undefined) {
      check("public HTML renders the changelog title", publicHtml.includes("MCP Contract"), "title missing");
      check(
        "public HTML renders the configured logo",
        publicHtml.includes("https://example.com/mcp-contract-logo.svg"),
        "logo missing",
      );
    }
    const rssBody = publicUrl ? await fetchPublic(`${publicUrl}.rss`, "public RSS") : undefined;
    const jsonBody = publicUrl ? await fetchPublic(`${publicUrl}.json`, "public JSON") : undefined;
    const publicBodies = [
      ["public HTML", publicHtml],
      ["public RSS", rssBody],
      ["public JSON", jsonBody],
    ].filter(([, body]) => body !== undefined);
    const forbiddenPublicFields = [
      ["entry handle", entryHandle],
      ["internal id", entry?.id],
      ["actor email", "@example.com"],
      ["source reference URL", "https://example.com/mcp-lifecycle"],
      ["second source reference URL", "https://example.com/mcp-lifecycle-revision"],
      ["revision identifier", "revision_number"],
      ["grant field", "grant_id"],
      ["audit field", "inserted_at"],
    ].filter(([, value]) => value);
    for (const [label, body] of publicBodies) {
      for (const [field, value] of forbiddenPublicFields) {
        check(`${label} omits ${field}`, !body.includes(value), `found=${value}`);
      }
    }

    const archived = await call(client, "archive entry", "changelog.archive_entry", {
      project_handle: PROJECT_HANDLE,
      entry_handle: entryHandle,
      idempotency_key: `lifecycle-archive-${runId}`,
    });
    check("archive transitions the entry to archived", contentJson(archived)?.entry?.status === "archived", resultDetail(archived));

    const invalidPublish = await client.callTool(
      gatewayCall("changelog.publish_entry", {
        project_handle: PROJECT_HANDLE,
        entry_handle: entryHandle,
        expected_revision: revision?.revision_number,
        idempotency_key: `lifecycle-invalid-publish-${runId}`,
      }),
    );
    checkEqual(
      "publishing an archived entry returns invalid_state_transition",
      domainCode(invalidPublish),
      "invalid_state_transition",
    );
    if (entryPublicUrl) await publicRequest(entryPublicUrl, 404, "archived entry URL");

    const restored = await call(client, "restore entry", "changelog.restore_entry", {
      project_handle: PROJECT_HANDLE,
      entry_handle: entryHandle,
      idempotency_key: `lifecycle-restore-${runId}`,
    });
    check("restore transitions the entry back to draft", contentJson(restored)?.entry?.status === "draft", resultDetail(restored));

    const deletion = await call(client, "request destructive deletion", "changelog.delete_entry", {
      project_handle: PROJECT_HANDLE,
      entry_handle: entryHandle,
      idempotency_key: `lifecycle-delete-${runId}`,
    });
    const confirmationId = contentJson(deletion)?.confirmation_id;
    check(
      "destructive deletion creates a pending confirmation",
      typeof confirmationId === "string" && contentJson(deletion)?.status === "pending",
      resultDetail(deletion),
    );
    const confirmation = await call(client, "read destructive confirmation", "confirmations.get", {
      confirmation_id: confirmationId,
    });
    check(
      "confirmation lookup remains pending before approval",
      contentJson(confirmation)?.status === "pending",
      resultDetail(confirmation),
    );
  } finally {
    await client.close().catch(() => undefined);
    await transport.close().catch(() => undefined);
  }

  console.log(`RESULT: ${passed} passed, ${failed} failed`);
  if (failed > 0) process.exitCode = 1;
}

main().catch((error) => {
  console.error(`mcp-lifecycle: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
});
