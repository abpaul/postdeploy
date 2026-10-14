defmodule AlplusWeb.AgentConnection do
  @moduledoc """
  Answers one question for the console: does this project have a connected
  agent right now?

  Every first-run card states a connection state, and before this module three
  screens answered it with `Phoenix.LiveView.connected?/1`. That reports the
  browser's websocket, so a project with no MCP grant at all read
  "Connection state: Connected, identity evidence is empty" the moment the
  socket upgraded. The connection the reader cares about is the agent's.

  The answer is one indexed, org and project scoped read, and it only runs on
  a screen that has no evidence to show.
  """

  require Ash.Query

  alias Alplus.Mcp

  @doc """
  `:awaiting_evidence` when this project has an MCP OAuth grant,
  `:not_connected` otherwise. These are exactly the two states
  `AlplusWeb.ConsoleComponents.first_run_card/1` renders.

  A read failure answers `:not_connected`, which is the safe direction: it
  offers to connect an agent rather than claiming one is already there.
  """
  @spec state(map()) :: :awaiting_evidence | :not_connected
  def state(scope) do
    if connected?(scope), do: :awaiting_evidence, else: :not_connected
  end

  @doc "True when this org and project have at least one MCP OAuth grant."
  @spec connected?(map()) :: boolean()
  def connected?(%{org_id: org_id, project_id: project_id} = scope)
      when not is_nil(org_id) and not is_nil(project_id) do
    query =
      Mcp.OAuthGrant
      |> Ash.Query.filter(org_id == ^org_id and project_id == ^project_id)
      |> Ash.Query.limit(1)

    # `list_oauth_grants/1` is owner and admin only; connection evidence is
    # readable by every member, so authorization is resolved by the scope above.
    case Mcp.list_oauth_grants(query: query, actor: scope, authorize?: false) do
      {:ok, grants} -> grants != []
      {:error, _reason} -> false
    end
  end

  def connected?(_scope), do: false
end
