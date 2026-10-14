---
title: "JavaScript source maps: verify the exact deployed build"
description: "Keep minified bundles, source maps, and release identifiers aligned. Diagnose missing frames with a deliberate test error from the deployed artifact."
slug: "javascript-source-maps-release-checklist"
published_at: "2026-11-23T09:00:00Z"
cluster: "errors"
intent: "informational"
keywords:
  - "javascript source maps production"
  - "source map release mismatch"
  - "minified stack trace debugging"
internal_links:
  - "/error-tracking"
  - "/guides/investigate-errors-after-release"
  - "/blog/error-grouping-fingerprints"
sources:
  - "https://tc39.es/ecma426/"
  - "https://docs.sentry.io/platforms/javascript/sourcemaps/"
---

A source map translates a location in generated JavaScript into a location in the original source. The map must describe the exact bundle that caused the error. Rebuilding from the same commit can still produce a different artifact.

Treat bundles and maps as one release artifact. Build once, preserve that output, upload the matching maps through the error tracker's supported path, and deploy those same bundles.

## Match artifact identity before debugging options

An illustrative release record can contain:

~~~json
{
  "release": "web-7c2e1f",
  "assets": [
    {
      "bundle": "assets/app.a83d91.js",
      "map": "assets/app.a83d91.js.map"
    }
  ]
}
~~~

The filenames are examples. Some trackers identify files by URL and release; others support embedded debug identifiers. Use the identity mechanism that your integration documents.

A release tag alone does not establish that a map matches the bytes. Preserve checksums or immutable artifact paths with the deployment record.

## Verify the map's basic structure

A source map commonly includes `version`, `sources`, `names`, and `mappings`. Inline original source content is optional.

Use this Node.js script against your own generated map:

~~~javascript
import { readFileSync } from "node:fs";

const map = JSON.parse(readFileSync(process.argv[2], "utf8"));
if (map.version !== 3 ||
    !Array.isArray(map.sources) ||
    typeof map.mappings !== "string") {
  throw new Error("Unexpected source map structure");
}
console.log({
  sources: map.sources.length,
  includesSource: Array.isArray(map.sourcesContent)
});
~~~

Run it as `node check-map.mjs path/to/app.js.map`. This checks shape. It does not prove accurate mapping or successful ingestion.

A tracker may show original filenames without source context when the map omits `sourcesContent`. Decide whether that is sufficient for investigation.

## Produce one controlled error

Use a disposable environment built with the production build configuration. Trigger an exception from a known source line after the deployed page loads.

Verify that the received event contains the expected release, bundle URL or debug identifier, original file, function, and line. Inspect the event in the actual tracker.

Do not rely only on an upload command's exit code. Upload success proves acceptance of files, while the event proves that lookup and mapping work together.

Repeat after a deployment changes the public asset prefix, CDN hostname, or bundler configuration. These changes can break identity matching without changing application logic.

## Diagnose the common mismatch paths

A missing artifact suggests an upload or lookup failure. A frame mapped to the wrong source line suggests mismatched bundle and map bytes. A stale release value can point events to another deployment.

Check CDN caching. An old browser tab can keep executing an older bundle after a new deployment. Retain maps for builds that users may still run, within your storage and retention policy.

Do not overwrite an immutable artifact name with new bytes. Cache layers can then serve a mixture of versions that share the same identity.

## Choose source visibility deliberately

Public maps may expose source text and comments. Private artifact uploads can make maps available to the tracker without putting them on the public asset host, when the tracker supports that workflow.

Do not hide maps by simply removing a reference comment and assume the files are private. Test whether their URLs are reachable.

[PostDeploy error tracking](/error-tracking) supports release context and source map symbolication. Follow its supported artifact upload instructions; do not assume another vendor's debug identifier flow is compatible.

Accurate frames also support [stable error grouping](/blog/error-grouping-fingerprints). Finish with one deliberately generated event whose mapped source location you can verify.

## References

- [Source map specification](https://tc39.es/ecma426/)
- [Sentry source map documentation](https://docs.sentry.io/platforms/javascript/sourcemaps/)
