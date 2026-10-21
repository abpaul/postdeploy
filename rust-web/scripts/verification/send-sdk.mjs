import * as http from 'node:http';
import { createHash } from 'node:crypto';
import * as Sentry from '@sentry/node';

export async function sendSdk({ dsn, errorMarker, logMarker, paddingBytes = 0 }) {
  const target = new URL(dsn);
  if (!['127.0.0.1', 'localhost', '[::1]'].includes(target.hostname)) {
    throw new Error('The SDK verification target must be loopback');
  }
  const receipt = { sdk: '@sentry/node', version: Sentry.SDK_VERSION, envelopes: [], requests: [], eventId: null };
  const instrumentedHttp = {
    ...http,
    request(options, callback) {
      receipt.requests.push({ encoding: options.headers?.['content-encoding'] ?? 'identity' });
      return http.request(options, callback);
    },
  };
  Sentry.init({
    dsn,
    defaultIntegrations: false,
    sendClientReports: false,
    sendDefaultPii: false,
    enableLogs: true,
    release: 'postdeploy-verification@1.0.0',
    environment: 'verification',
    transport(options) {
      const transport = Sentry.makeNodeTransport({ ...options, httpModule: instrumentedHttp, keepAlive: false });
      return {
        async send(envelope) {
          const observed = { types: [], logCount: 0, status: null, failed: false, traceIds: [] };
          for (const [header, payload] of envelope[1]) {
            observed.types.push(header.type);
            if (header.type === 'log' && payload && Array.isArray(payload.items)) {
              observed.logCount += payload.items.length;
              observed.traceIds.push(...payload.items.map(item => item.trace_id).filter(Boolean));
            }
          }
          receipt.envelopes.push(observed);
          try {
            const response = await transport.send(envelope);
            observed.status = response.statusCode ?? null;
            return response;
          } catch {
            observed.failed = true;
            throw new Error('SDK transport failed');
          }
        },
        flush(timeout) { return transport.flush(timeout); },
      };
    },
  });
  Sentry.withScope(scope => {
    scope.setTag('verification', 'real-sdk');
    scope.setContext('request', { request_id: 'verification-request' });
    Sentry.addBreadcrumb({ category: 'verification', message: 'The verification request started', level: 'info' });
    receipt.eventId = Sentry.captureException(new Error(errorMarker));
    Sentry.logger.info(logMarker + 'x'.repeat(paddingBytes), {
      request_id: 'verification-request',
      authorization: 'Bearer verification-sensitive-value',
      email: 'private-verification@example.invalid',
    });
  });
  receipt.flushed = await Sentry.flush(30_000);
  await Sentry.close(5_000);
  receipt.logDigest = createHash('sha256').update(logMarker).digest('hex');
  return receipt;
}
