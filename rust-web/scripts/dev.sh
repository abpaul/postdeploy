#!/bin/sh
set -eu

if [ "$#" -ne 0 ]; then
  echo "Usage: scripts/dev.sh" >&2
  exit 2
fi

cd -P "$(dirname "$0")/.."

environment=${POSTDEPLOY_DEV_ENVIRONMENT:-development}
case "$environment" in
  development|test) ;;
  *) echo "Local development requires the development or test environment." >&2; exit 2 ;;
esac

POSTDEPLOY_CREDENTIALS_FILE=${POSTDEPLOY_CREDENTIALS_FILE:-config/credentials/$environment.toml.enc}
if [ ! -r "$POSTDEPLOY_CREDENTIALS_FILE" ]; then
  echo "Missing local credentials: $POSTDEPLOY_CREDENTIALS_FILE. Follow Local development in README.md." >&2
  exit 1
fi

if [ "${CREDSEAL_KEY_FILE+x}" != x ] && [ "${CREDSEAL_MASTER_KEY+x}" != x ]; then
  CREDSEAL_KEY_FILE=config/credentials/$environment.key
  export CREDSEAL_KEY_FILE
fi
if [ "${CREDSEAL_KEY_FILE+x}" = x ] && [ ! -r "$CREDSEAL_KEY_FILE" ]; then
  echo "Missing local Credseal key. Restore the existing key or follow Local development in README.md." >&2
  exit 1
fi

POSTDEPLOY_STORAGE_PREFIX=${POSTDEPLOY_STORAGE_PREFIX:-local-verification/dev/}
case "$POSTDEPLOY_STORAGE_PREFIX" in
  local-verification/*/) ;;
  *) echo "Local development requires a local-verification/ storage prefix ending in /." >&2; exit 2 ;;
esac

umask 077
mkdir -p "data/$environment/tenants"
DATABASE_URL="sqlite://$PWD/data/$environment/control.sqlite?mode=rwc"
POSTDEPLOY_TENANT_ROOT="$PWD/data/$environment/tenants"

export POSTDEPLOY_CREDENTIALS_FILE DATABASE_URL POSTDEPLOY_TENANT_ROOT POSTDEPLOY_STORAGE_PREFIX
export CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-2}
export CARGO_PROFILE_DEV_DEBUG=${CARGO_PROFILE_DEV_DEBUG:-0}

echo "Starting PostDeploy ($environment) at http://127.0.0.1:5167. Stop with Ctrl+C."
exec cargo run --locked --bin postdeploy-cli -- start --environment "$environment"
