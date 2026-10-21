import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { sendSdk } from './send-sdk.mjs';
import { opendir, readFile, stat } from 'node:fs/promises';
import { resolve } from 'node:path';

const origin = new URL(process.argv[2] || 'http://127.0.0.1:5167');
assert(origin.hostname === '127.0.0.1' && origin.protocol === 'http:', 'Use the isolated loopback application');
const stats = { requests: 0, sdkErrors: 0, sdkLogs: 0, searchRows: 0, replayRows: 0, isolationChecks: 0 };
let stage = 'signup';

async function request(path, { session, method = 'GET', body, status = 200, headers = {} } = {}) {
  stats.requests++;
  const response = await fetch(new URL(path, origin), {
    method,
    headers: {
      ...(session ? { Cookie: session.cookie, 'X-CSRF-Token': session.csrf } : {}),
      ...(body ? { 'Content-Type': 'application/json' } : {}),
      ...headers,
    },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(30_000),
    redirect: 'manual',
  });
  assert(response.status === status, 'The API returned an unexpected status');
  return response;
}

async function signup() {
  const response = await request('/api/auth/signup', {
    method: 'POST', status: 201,
    body: { email: `local-${randomUUID()}@example.invalid`, password: randomUUID() },
  });
  const body = await response.json();
  assert(body.csrf_token && body.user?.id, 'Account setup did not return a session');
  return { cookie: response.headers.get('set-cookie').split(';')[0], csrf: body.csrf_token };
}

async function replay(session, org, after, expected) {
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), 15_000);
  let reader;
  try {
    const response = await fetch(new URL(`/api/orgs/${org}/logs/tail`, origin), {
      headers: { Cookie: session.cookie, 'Last-Event-ID': after }, signal: abort.signal,
    });
    assert(response.status === 200, 'The live tail did not open');
    reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';
    let readBytes = 0;
    while (true) {
      const { value, done } = await reader.read();
      assert(!done, 'The live tail closed before replay');
      readBytes += value.length;
      assert(readBytes <= 1_048_576, 'The live tail exceeded the verification budget');
      buffer += decoder.decode(value, { stream: true }).replaceAll('\r\n', '\n');
      let split;
      while ((split = buffer.indexOf('\n\n')) >= 0) {
        const event = buffer.slice(0, split);
        buffer = buffer.slice(split + 2);
        if (!event.includes('event: entries')) continue;
        const data = event.split('\n').filter(line => line.startsWith('data:')).map(line => line.slice(5).trimStart()).join('\n');
        const batch = JSON.parse(data);
        if (batch.rows?.some(row => row.body.startsWith(expected))) {
          stats.replayRows += batch.rows.length;
          return;
        }
      }
    }
  } finally {
    clearTimeout(timer);
    abort.abort();
    await reader?.cancel().catch(() => {});
  }
}

async function inspectLocal(root, markers) {
  let scannedBytes = 0;
  let files = 0;
  async function scan(path) {
    const info = await stat(path);
    if (info.isDirectory()) {
      for await (const entry of await opendir(path)) {
        assert(!entry.isSymbolicLink(), 'The local scan root contains an unexpected symbolic link');
        await scan(resolve(path, entry.name));
      }
    } else if (info.isFile()) {
      scannedBytes += info.size;
      assert(scannedBytes <= 256 * 1024 * 1024, 'The local scan exceeded its byte budget');
      const bytes = await readFile(path);
      assert(markers.every(marker => !bytes.includes(Buffer.from(marker))), 'An application log body was persisted locally');
      files++;
    }
  }
  await scan(resolve(root));
  assert(files > 0 && scannedBytes > 0, 'The local scan did not inspect files');
  return { files, scannedBytes };
}

try {
  const session = await signup();
  stage = 'project-and-dsn';
  const org = await (await request('/api/orgs', { session, method: 'POST', body: { name: 'Local verification' }, status: 201 })).json();
  const project = await (await request(`/api/orgs/${org.id}/projects`, { session, method: 'POST', body: { name: 'SDK verification' }, status: 201 })).json();
  const source = await (await request(`/api/orgs/${org.id}/projects/${project.id}/sources`, {
    session, method: 'POST', body: { name: 'Node verification', environment: 'verification' }, status: 201,
  })).json();
  assert(typeof source.dsn === 'string', 'Source setup did not return a DSN');
  const marker = `local-log-${randomUUID()}`;
  stage = 'real-sdk-ingestion';
  const receipt = await sendSdk({ dsn: source.dsn, errorMarker: 'Local verification exception', logMarker: marker, paddingBytes: 40_000 });
  stats.sdkEnvelopes = receipt.envelopes.map(({types,status,logCount}) => ({types,status,logCount}));
  assert(receipt.flushed && receipt.envelopes.every(item => item.status === 200), 'The SDK batch was not accepted');
  stats.sdkErrors = receipt.envelopes.filter(item => item.types.includes('event')).length;
  stats.sdkLogs = receipt.envelopes.reduce((sum, item) => sum + item.logCount, 0);
  stage = 'issue-evidence';
  const issues = await (await request(`/api/orgs/${org.id}/issues?project=${project.id}`, { session })).json();
  assert(issues.issues?.length === 1, 'The SDK error did not create one issue');
  const issue = issues.issues[0];
  const detail = await (await request(`/api/orgs/${org.id}/issues/${issue.id}`, { session })).json();
  const eventId = detail.latest_event?.event_id;
  assert(eventId, 'Issue event context is missing');
  const event = await (await request(`/api/orgs/${org.id}/issues/${issue.id}/events/${eventId}`, { session })).json();
  assert(event.payload?.exception?.values?.some(value => value.stacktrace?.frames?.length), 'The SDK stack trace is missing');
  assert(event.payload.release === 'postdeploy-verification@1.0.0', 'The SDK release is missing');
  stage = 'r2-backed-search';
  const page = await (await request(`/api/orgs/${org.id}/logs?q=${encodeURIComponent(marker)}`, { session })).json();
  assert(page.rows?.length === 1 && page.rows[0].body.startsWith(marker), 'R2-backed search did not return the SDK log');
  assert(page.coverage?.bytes > 0, 'Search did not read durable object bytes');
  assert(!JSON.stringify(page.rows).includes('verification-sensitive-value'), 'Sensitive attributes were not scrubbed');
  stats.searchRows = page.rows.length;
  stage = 'tail-reconnect';
  const cursor = page.rows[0].cursor;
  const nextMarker = `local-log-${randomUUID()}`;
  const nextReceipt = await sendSdk({ dsn: source.dsn, errorMarker: 'Local verification exception', logMarker: nextMarker });
  assert(nextReceipt.envelopes.every(item => item.status === 200), 'The second SDK batch was not accepted');
  await replay(session, org.id, cursor, nextMarker);
  stage = 'tenant-isolation';
  const stranger = await signup();
  await request(`/api/orgs/${org.id}/logs`, { session: stranger, status: 404 });
  await request(`/api/orgs/${org.id}/issues/${issue.id}`, { session: stranger, method: 'PATCH', body: { status: 'resolved' }, status: 404 });
  stats.isolationChecks += 2;
  const dsnKey = new URL(source.dsn).username;
  await request(`/api/orgs/${org.id}/logs`, { headers: { Authorization: `Bearer ${dsnKey}` }, status: 401 });
  stats.isolationChecks++;
  if (process.argv[3]) {
    stage = 'local-payload-absence';
    stats.localScan = await inspectLocal(process.argv[3], [marker, nextMarker]);
  }
  console.log(JSON.stringify({ status: 'PASS', ...stats }));
} catch {
  console.log(JSON.stringify({ status: 'FAIL', stage, ...stats }));
  process.exitCode = 1;
}
