#!/bin/sh
set -eu
ulimit -c 0

if [ "${POSTDEPLOY_REQUIRE_VOLUME:-false}" = true ]; then
  [ "$(cat /data/.postdeploy-volume 2>/dev/null)" = postdeploy-rust-candidate-v1 ] || {
    echo "The dedicated PostDeploy Rust data volume is not mounted" >&2
    exit 1
  }
fi

exec "$@"
