# Opens the connect gate for the visual-review workspace by writing the one
# allowed agent audit row an MCP tool call records in production. Development
# only: it lets a reviewer reach the authenticated data screens without
# standing up an MCP client.
defmodule Alplus.VisualConnect do
  @moduledoc false

  require Ash.Query

  alias Alplus.{Orgs, Scope}
  alias Alplus.Accounts.User

  @email "visual-review@example.com"

  def run do
    unless Application.get_env(:alplus, :env) == :dev or Mix.env() == :dev do
      raise "visual_connect.exs is a development-only script"
    end

    user =
      User
      |> Ash.Query.filter(email == ^@email)
      |> Ash.read_one!(authorize?: false)

    user_scope = Scope.for_user(user.id)
    [org | _] = Orgs.list_organizations!(actor: user_scope)
    {:ok, org_scope} = Orgs.build_scope(user_scope, org.id)

    for project <- Alplus.Projects.list_projects_for_org!(org.id, actor: org_scope) do
      Alplus.Audit.write(%{
        actor: Scope.put_project(org_scope, project.id),
        org_id: org.id,
        project_id: project.id,
        grant_id: Alplus.Id.generate(:mcp_oauth_grant),
        actor_kind: "agent",
        transport: "remote_mcp",
        action: "monitor.list",
        subject_type: "mcp_tool",
        outcome: "allowed",
        request_id: Alplus.Id.generate(:request)
      })

      IO.puts("connected #{project.name} (#{project.public_token})")
    end
  end
end

Alplus.VisualConnect.run()
