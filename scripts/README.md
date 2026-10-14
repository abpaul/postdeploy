# scripts/

Operational scripts. Each is safe to run repeatedly and prints what it
observed rather than only a pass/fail.

## Checks

**`acceptance-smoke.sh`** — drives the public surface of a running server over
HTTP and maps each check to an explicit requirement: crawl surface, the
monitoring cluster and guides, metadata and structured data, the JavaScript
payload, the machine-readable surfaces, and the 404. Defaults to
`http://localhost:4000`; edit `B` at the top to point it elsewhere.

```sh
mix phx.server &
scripts/acceptance-smoke.sh
```

Use it after a deploy, against the real hostname, and after any change to the
marketing surface.

## Setup and assets

**`build-og-image.sh`** — rasterizes `priv/static/images/og-default.svg` to the
1200x630 PNG used for social previews. Edit the SVG, then run this; social
platforms do not render SVG. Needs `rsvg-convert` (`brew install librsvg`).

**`postgres-local/`** — init scripts for the disposable developer Postgres in
`compose.postgres.yml`. Never a production target.

## Related commands

These live in mix rather than here:

* `mix alplus.seo.audit` — renders every public route and fails on SEO or
  accessibility defects. Runs in CI through `Alplus.Seo.AuditTest`.
* `mix alplus.growth.report [--days N]` — the acquisition funnel by content
  cluster, from attributed signup through to activation.
* `mix alplus.loadtest` — load-checks monitors and ingest.
