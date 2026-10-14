---
title: "Diagnose TLS certificate errors: hostname, chain, or expiry?"
description: "Use curl and OpenSSL to separate certificate expiry, hostname mismatch, and chain failures. Check the public edge and origin without disabling validation."
slug: "tls-hostname-chain-diagnostics"
published_at: "2027-01-04T09:00:00Z"
cluster: "uptime"
intent: "informational"
keywords:
  - "TLS certificate hostname mismatch"
  - "SSL certificate chain error"
  - "diagnose HTTPS certificate failure"
internal_links:
  - "/monitoring/uptime"
  - "/guides/ssl-certificate-expiry"
  - "/blog/http-health-check-contract"
sources:
  - "https://docs.openssl.org/3.0/man1/openssl-s_client/"
  - "https://curl.se/docs/sslcerts.html"
---

An unexpired certificate can still fail validation. The requested hostname may be absent, the server may omit an intermediate certificate, or the client may not trust the issuing authority.

Diagnose these separately. Replacing the certificate without identifying the failure can leave the same outage in place.

## Start with the failing hostname

Run a request using the exact public hostname:

~~~sh
curl --verbose --connect-timeout 5 --max-time 15 \
  https://app.example.com/ready
~~~

Use a host you control. Keep diagnostic output restricted because HTTP headers can contain sensitive information.

Read the TLS error before interpreting the application response. A failed TLS handshake means the client may never have sent the HTTP request.

Do not add `--insecure` to an uptime check. That would remove part of the condition users depend on. A request passing with validation disabled only narrows the investigation; it does not establish a healthy HTTPS service.

## Inspect the served certificate chain

OpenSSL can show the certificates returned for a particular server name:

~~~sh
openssl s_client \
  -connect app.example.com:443 \
  -servername app.example.com \
  -verify_hostname app.example.com \
  -verify_return_error \
  -showcerts </dev/null
~~~

Use the trust configuration appropriate to your environment. OpenSSL and a browser may use different trust stores.

The server name selects the certificate on a host serving several HTTPS sites. The hostname verification checks whether that selected certificate covers the requested name. Those are separate responsibilities.

Inspect validity dates and subject alternative names. A wildcard such as `*.example.com` generally covers one subdomain level, not every nested name.

## Compare the public edge with the origin

A CDN can terminate TLS with one certificate while its connection to the origin uses another. Renewing the origin certificate does not automatically repair the public edge certificate.

To test a known origin address while preserving the URL hostname and TLS server name, use curl's address override:

~~~sh
curl --verbose --connect-timeout 5 --max-time 15 \
  --resolve app.example.com:443:192.0.2.10 \
  https://app.example.com/ready
~~~

The address is a documentation placeholder. Use your authorized origin address. A private origin may require a VPN or a restricted host; do not expose it just to run this test.

An origin configured to accept only CDN traffic can reject the direct request. That rejection does not prove the CDN path is broken.

## Distinguish trust from chain delivery

A private certificate authority can be valid for an internal service while a public monitor rejects it. Configure the appropriate trust only when the monitor supports that use case.

A server should present the needed intermediate chain. Do not rely on one browser's cached intermediate certificates as proof that every client can validate the service.

Test from a clean client environment. Record the hostname, connection address, trust store, and observed verification result so another developer can repeat the check.

## Add the right monitoring evidence

[Certificate expiry monitoring](/guides/ssl-certificate-expiry) detects one predictable risk. It does not replace an HTTPS request that validates the hostname and trust chain.

[PostDeploy uptime monitoring](/monitoring/uptime) can watch the public HTTPS path. Check the [health endpoint contract](/blog/http-health-check-contract) to ensure that a successful TLS connection also returns the expected application response.

After repair, repeat the original failing command with validation enabled. Then inspect the monitor's recovery and notification evidence. A successful renewal command is weaker evidence than a successful request through the path your users take.

## References

- [OpenSSL client diagnostics](https://docs.openssl.org/3.0/man1/openssl-s_client/)
- [curl certificate verification](https://curl.se/docs/sslcerts.html)
