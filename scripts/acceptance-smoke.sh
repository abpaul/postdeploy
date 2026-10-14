#!/usr/bin/env bash
# Drives the real public interface over HTTP against a running server.
# Each line maps one explicit PRD requirement to an observed result.
#
#   scripts/acceptance-smoke.sh                       # local dev server
#   scripts/acceptance-smoke.sh https://postdeploy.dev      # production host
B="${1:-http://localhost:4000}"
pass=0; fail=0
chk() { # chk "requirement" "expected" "actual"
  if [ "$2" = "$3" ]; then printf "  PASS  %-52s %s\n" "$1" "$3"; pass=$((pass+1));
  else printf "  FAIL  %-52s want=%s got=%s\n" "$1" "$2" "$3"; fail=$((fail+1)); fi
}
code() { curl -s --connect-timeout 5 --max-time 15 -o /dev/null -w "%{http_code}" "$B$1"; }
body() { curl -s --connect-timeout 5 --max-time 15 "$B$1"; }

echo "--- PRD 5: crawl and index ---"
chk "robots.txt serves"            200 "$(code /robots.txt)"
chk "sitemap.xml serves"           200 "$(code /sitemap.xml)"
chk "sitemap lists 16+ urls"       yes "$([ "$(body /sitemap.xml | grep -c '<loc>')" -ge 16 ] && echo yes)"
chk "trailing slash 301s"          301 "$(code /monitoring/)"
chk "auth disallowed in robots"    yes "$(body /robots.txt | grep -q 'Disallow: /register' && echo yes)"

echo "--- PRD 11/12: monitoring cluster + guides ---"
for p in /monitoring /monitoring/uptime /monitoring/cron-jobs /monitoring/api \
         /guides/github-actions-heartbeat /guides/kubernetes-cronjob-heartbeat /privacy; do
  chk "$p serves" 200 "$(code $p)"
done

echo "--- PRD 6/7: metadata + structured data ---"
H=$(body /monitoring/cron-jobs)
# `<title` not `<title>`: LiveView's `live_title` adds attributes to the tag.
chk "has title"          yes "$(echo "$H" | grep -q '<title' && echo yes)"
chk "has description"    yes "$(echo "$H" | grep -q 'name="description"' && echo yes)"
chk "has canonical"      yes "$(echo "$H" | grep -q 'rel="canonical"' && echo yes)"
chk "has og:image"       yes "$(echo "$H" | grep -q 'property="og:image"' && echo yes)"
chk "has twitter:card"   yes "$(echo "$H" | grep -q 'name="twitter:card"' && echo yes)"
chk "has JSON-LD"        yes "$(echo "$H" | grep -q 'application/ld+json' && echo yes)"

echo "--- PRD 8: performance ---"
if echo "$H" | grep -q 'assets/js/app.js'; then jsbundle=present; else jsbundle=absent; fi
chk "no LiveView bundle on marketing" absent "$jsbundle"
chk "og image serves"                 200 "$(code /images/og-default.png)"

echo "--- PRD 19: machine-readable surfaces ---"
# /product-facts.json and /pricing.md were removed in the sell-first rewrite
# (fd10d3c); llms.txt and the sitemap are the surviving machine surfaces.
chk "llms.txt serves"          200 "$(code /llms.txt)"
chk "sitemap.xml serves"       200 "$(code /sitemap.xml)"

echo "--- PRD 36: 404 ---"
chk "unknown path 404s" 404 "$(code /no-such-page)"

echo "--- SDK contract: the host every published SDK defaults to ---"
# @alplus/sdk, alplus_sdk and alplus-ruby all default to https://ingest.postdeploy.dev.
# It had no DNS record until 2026-08-20, so every third-party install posted
# into the void with no error anyone could act on. Nothing in the suite could
# catch that: it is DNS and edge routing, not code.
ingest_health=$(curl -s --max-time 15 https://ingest.postdeploy.dev/health)
chk "ingest.postdeploy.dev health"  ok  "$ingest_health"
chk "ingest rejects an unkeyed error post" 401 \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST https://ingest.postdeploy.dev/e/errors)"
chk "ingest rejects an unkeyed session post" 401 \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST https://ingest.postdeploy.dev/e/sessions)"
# The path a Sentry SDK derives from a DSN on this host.
chk "ingest rejects an unkeyed Sentry envelope" 401 \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST https://ingest.postdeploy.dev/api/1/envelope/)"

echo "--- sign-up is actually protected ---"
# Cloudflare's testing site keys render a widget stamped "For testing only" and
# their secret validates every token, so the form works and protects nothing.
# Production ran that way until 2026-08-20. A real key starts 0x4A; the widget
# script itself is injected by a JS hook, so only the key is in the HTML.
register_html=$(body /register)
chk "turnstile sitekey rendered"  yes \
  "$(echo "$register_html" | grep -q 'sitekey="0x4A' && echo yes)"
chk "turnstile key is not a test key" yes \
  "$(echo "$register_html" | grep -qE 'sitekey="[123]x0+' && echo no || echo yes)"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
