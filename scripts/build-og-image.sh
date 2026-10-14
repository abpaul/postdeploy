#!/usr/bin/env bash
# Regenerates the Open Graph social preview image.
#
# Social images are static: one 1200x630 PNG served for every page. Per-page
# generated images would need a rendering service and a cache, which is a lot
# of infrastructure for a link preview, and a wrong-but-specific image is
# worse than a correct generic one.
#
# The SVG source is the file to edit. This script only rasterizes it, because
# X and LinkedIn do not render SVG previews.
#
# Requires rsvg-convert (brew install librsvg).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

src="$root/priv/static/images/og-default.svg"
out="$root/priv/static/images/og-default.png"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "rsvg-convert not found. Install it with: brew install librsvg" >&2
  exit 1
fi

# 1200x630 is the size X, LinkedIn, Slack and Facebook all accept without
# re-cropping.
rsvg-convert --width=1200 --height=630 "$src" --output "$out"

echo "Wrote $out"
ls -lh "$out" | awk '{print "  " $5}'
