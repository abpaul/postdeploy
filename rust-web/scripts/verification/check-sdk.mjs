import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { gunzipSync } from 'node:zlib';
import { sendSdk } from './send-sdk.mjs';

const observed = { requests: 0, errors: 0, logs: 0, gzip: 0, failures: 0 };
const receiverStatus = Number(process.argv[2] ?? 200);
assert([200, 401, 503].includes(receiverStatus), 'Unsupported verification receiver status');
const logMarker = `log-${randomUUID()}`;
const errorMarker = `error-${randomUUID()}`;
const server = createServer(async (request, response) => {
  try {
    const chunks = [];
    let size = 0;
    for await (const chunk of request) {
      size += chunk.length;
      assert(size <= 1_048_576, 'SDK request exceeded the verification receiver limit');
      chunks.push(chunk);
    }
    let body = Buffer.concat(chunks);
    if (request.headers['content-encoding'] === 'gzip') {
      observed.gzip++;
      body = gunzipSync(body, { maxOutputLength: 4_194_304 });
    }
    const lines = body.toString('utf8').trimEnd().split('\n');
    JSON.parse(lines.shift());
    while (lines.length) {
      const header = JSON.parse(lines.shift());
      const payload = JSON.parse(lines.shift());
      if (header.type === 'event') {
        observed.errors++;
        assert(payload.exception?.values?.some(value => value.value === errorMarker), 'SDK error evidence is missing');
        assert(payload.release === 'postdeploy-verification@1.0.0', 'SDK release context is missing');
        assert(payload.breadcrumbs?.some(value => value.category === 'verification'), 'SDK breadcrumb is missing');
      } else if (header.type === 'log') {
        observed.logs += payload.items.length;
        assert(header.item_count === payload.items.length, 'SDK log item count does not match');
        assert(header.content_type === 'application/vnd.sentry.items.log+json', 'SDK log content type is wrong');
        assert(payload.items.some(item => item.body.startsWith(logMarker)), 'SDK log body is missing');
        assert(payload.items.every(item => /^[a-f0-9]{32}$/.test(item.trace_id)), 'SDK trace correlation is missing');
      }
    }
    observed.requests++;
    response.writeHead(receiverStatus, { 'content-type': 'application/json' }).end('{}');
  } catch {
    observed.failures++;
    response.writeHead(400).end();
  }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
try {
  const address = server.address();
  const receipt = await sendSdk({
    dsn: `http://${'a'.repeat(32)}@127.0.0.1:${address.port}/1`,
    errorMarker,
    logMarker,
    paddingBytes: 40_000,
  });
  assert(receipt.version === '11.6.0', 'Unexpected SDK version');
  assert(receipt.flushed, 'SDK did not finish flushing');
  assert(receipt.envelopes.every(item => item.status === receiverStatus && !item.failed), 'SDK transport did not observe the receiver status');
  assert(observed.errors === 1 && observed.logs === 1, 'SDK did not send exactly one error and one log');
  assert(observed.gzip >= 1, 'SDK did not exercise real transport gzip');
  assert(observed.failures === 0, 'The SDK receiver rejected work');
  assert(observed.requests === 2, 'The SDK unexpectedly retried an HTTP response');
  console.log(JSON.stringify({ status: 'PASS', receiverStatus, sdk: receipt.sdk, version: receipt.version, ...observed }));
} catch {
  console.log(JSON.stringify({ status: 'FAIL', ...observed }));
  process.exitCode = 1;
} finally {
  await new Promise(resolve => server.close(resolve));
}
