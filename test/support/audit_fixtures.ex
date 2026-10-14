defmodule Alplus.AuditFixtures do
  @moduledoc """
  Audit-row fixtures.

  `agent_audit_fixture/4` writes the allowed agent row that
  `Alplus.Audit.agent_connected?/2` treats as "an agent has reached this
  project" — the same row an MCP tool call records in production, so any
  test that mounts a project route can seed a connected project without
  reproducing the `Alplus.Audit.write/1` attribute map.
  """

  @doc """
  Writes one allowed agent audit row for `project`, acting as `scope`.

  `transport` must be an MCP transport (`"remote_mcp"` or `"webmcp"`);
  only those satisfy the connection predicate. `attrs` overrides
  `:grant_id` and `:action`.
  """
  def agent_audit_fixture(scope, project, transport \\ "remote_mcp", attrs \\ %{}) do
    Alplus.Audit.write(%{
      actor: Alplus.Scope.put_project(scope, project.id),
      org_id: scope.org_id,
      project_id: project.id,
      grant_id: Map.get(attrs, :grant_id, Alplus.Id.generate(:mcp_oauth_grant)),
      actor_kind: "agent",
      transport: transport,
      action: Map.get(attrs, :action, "monitor.list"),
      subject_type: "mcp_tool",
      outcome: "allowed",
      request_id: Alplus.Id.generate(:request)
    })
  end
end
