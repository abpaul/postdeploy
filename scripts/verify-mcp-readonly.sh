#!/usr/bin/env bash
# Verify read-only MCP access over HTTP.
# Required: MCP_ORG_ID, MCP_USER_ID, MCP_PROJECT_HANDLE (prefixed project id).
# Optional: MCP_OAUTH_ACCESS_TOKEN.
# Optional: MCP_URL, MCP_PORT, MCP_EXTERNAL_SERVER=1.
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 RUBYOPT=-Eutf-8
fail() { printf 'verify-mcp-readonly: %s\n' "$1" >&2; exit 1; }
: "${MCP_ORG_ID:?set MCP_ORG_ID to the test organization id}"
: "${MCP_USER_ID:?set MCP_USER_ID to the test user id}"
: "${MCP_PROJECT_HANDLE:?set MCP_PROJECT_HANDLE to the prefixed test project id}"
case "$MCP_PROJECT_HANDLE" in project_*) ;; *) fail "MCP_PROJECT_HANDLE must be a prefixed project id (project_…)" ;; esac
export MIX_ENV=dev
export MCP_PORT="${MCP_PORT:-4055}"
export MCP_URL="${MCP_URL:-http://127.0.0.1:${MCP_PORT}/mcp}"
export PORT="${PORT:-$MCP_PORT}"
command -v node >/dev/null 2>&1 || fail "Node 20 or newer is required"
node_major=$(node -p 'process.versions.node.split(".")[0]')
[ "$node_major" -ge 20 ] || fail "Node 20 or newer is required (found $node_major)"
server_pid=''; token_file=''; mint_log=''; log_file=$(mktemp "${TMPDIR:-/tmp}/alplus-mcp-readonly.XXXXXX.log")
cleanup() {
  if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  rm -f "$log_file"
  if [ -n "$token_file" ]; then rm -f "$token_file"; fi
  if [ -n "$mint_log" ]; then rm -f "$mint_log"; fi
}
trap cleanup EXIT INT TERM
if [ "${MCP_EXTERNAL_SERVER:-0}" != 1 ]; then
  printf 'verify-mcp-readonly: booting Phoenix on port %s\n' "$MCP_PORT"
  PORT="$MCP_PORT" mix phx.server >"$log_file" 2>&1 &
  server_pid=$!
fi
ready=0
for _ in $(seq 1 60); do
  status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' -X POST "$MCP_URL" -H 'Accept: application/json, text/event-stream' -H 'Content-Type: application/json' -H 'MCP-Protocol-Version: 2025-11-25' --data '{"jsonrpc":"2.0","id":"readiness","method":"initialize","params":{}}' || true)
  if [ "$status" = 401 ]; then ready=1; break; fi
  sleep 1
done
[ "$ready" -eq 1 ] || { cat "$log_file" >&2; fail "Phoenix endpoint did not return 401"; }
if [ -z "${MCP_OAUTH_ACCESS_TOKEN:-}" ]; then
printf 'verify-mcp-readonly: issuing disposable OAuth access token\n'
token_file=$(mktemp "${TMPDIR:-/tmp}/alplus-mcp-readonly-token.XXXXXX")
mint_log=$(mktemp "${TMPDIR:-/tmp}/alplus-mcp-readonly-mint.XXXXXX.log")
if ! MCP_TOKEN_FILE="$token_file" mix run -e '
  org_id = System.fetch_env!("MCP_ORG_ID")
  user_id = System.fetch_env!("MCP_USER_ID")
  token_file = System.fetch_env!("MCP_TOKEN_FILE")
  {:ok, actor} = Alplus.Orgs.build_scope(Alplus.Scope.for_user(user_id), org_id)
  project_handle = System.fetch_env!("MCP_PROJECT_HANDLE")
  unless String.starts_with?(project_handle, "project_"), do: raise("MCP_PROJECT_HANDLE must be a prefixed project id")
  project =
    Alplus.Projects.list_projects_for_org!(org_id, actor: actor)
    |> Enum.find(&(&1.id == project_handle))
  if is_nil(project), do: raise("read-only project not found")

  now = DateTime.utc_now()
  {:ok, client} =
    Alplus.Mcp.cache_oauth_client(
      %{
        issuer: Alplus.Mcp.OAuth.issuer(),
        client_id: "https://localhost/mcp-readonly.json",
        client_name: "MCP read-only verifier",
        redirect_uris: ["https://localhost/mcp-readonly/callback"],
        fetched_at: now,
        expires_at: DateTime.add(now, 3600, :second)
      },
      authorize?: false
    )
  scopes = [
    "analytics:read",
    "changelog:read",
    "errors:read",
    "monitor:read",
    "projects:read",
    "status:read"
  ]

  {:ok, grant} =
    Alplus.Mcp.authorize_oauth_grant(
      %{
        org_id: org_id,
        project_id: project.id,
        user_id: user_id,
        oauth_client_id: client.id,
        issuer: Alplus.Mcp.OAuth.issuer(),
        resource: Alplus.Mcp.OAuth.resource_uri(),
        scopes: scopes
      },
      actor: actor
    )

  {:ok, access_token} =
    Alplus.Mcp.issue_oauth_access_token(
      %{grant_id: grant.id, resource: Alplus.Mcp.OAuth.resource_uri(), scopes: scopes},
      authorize?: false
    )

  case Ash.Resource.get_metadata(access_token, :token) do
    token when is_binary(token) and token != "" -> File.write!(token_file, token)
    _ -> raise "OAuth access-token issuance did not return a token"
  end
' >"$mint_log" 2>&1; then
  cat "$mint_log" >&2
  fail "OAuth access-token issuance failed"
fi
MCP_OAUTH_ACCESS_TOKEN=$(cat "$token_file")
export MCP_OAUTH_ACCESS_TOKEN
rm -f "$token_file" "$mint_log"
token_file=''; mint_log=''
fi
cd "$repo_root/test/contract/mcp"
npm ci --silent
node readonly.mjs
