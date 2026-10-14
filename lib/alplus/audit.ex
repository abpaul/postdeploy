defmodule Alplus.Audit do
  @moduledoc """
  Security audit log (ARCHITECTURE.md §14 rule 5).

  `Alplus.Audit.Change` is what actually writes rows — attach it to a
  sensitive action with `change {Alplus.Audit.Change, action: "...", ...}`.
  `write/1` here is the low-level insert both that change and `AuditLog`'s
  own `:record` action policy expect; call it directly only for a case
  `Alplus.Audit.Change` cannot express (see its moduledoc).
  """

  use Ash.Domain,
    otp_app: :alplus

  resources do
    resource Alplus.Audit.AuditLog do
      define :list_audit_logs, action: :read
    end
  end

  require Ash.Query
  require Logger

  @doc """
  Writes one audit row with `authorize?: false`. Never raises: an audit
  write must never take down the mutation it is describing, which has
  already committed (or already failed) by the time this runs from
  `after_transaction`. Logs and returns `:ok` either way.
  """
  @spec write(map()) :: :ok
  def write(%{actor: actor} = attrs) do
    if match?(%Alplus.SystemActor{}, actor) do
      :ok
    else
      actor_id = actor && Map.get(actor, :user_id)
      org_id = attrs[:org_id] || (actor && Map.get(actor, :org_id))

      if is_nil(actor_id) or is_nil(org_id) do
        Logger.warning(
          "Alplus.Audit.write/1 skipped: missing actor or org_id for action=#{inspect(attrs[:action])}"
        )

        :ok
      else
        Alplus.Audit.AuditLog
        |> Ash.create(
          %{
            actor_id: actor_id,
            org_id: org_id,
            project_id: attrs[:project_id],
            grant_id: attrs[:grant_id],
            actor_kind: attrs[:actor_kind] || "user",
            transport: attrs[:transport] || "session",
            action: attrs[:action],
            subject_type: attrs[:subject_type],
            subject_id: attrs[:subject_id],
            outcome: attrs[:outcome],
            metadata: attrs[:metadata] || %{},
            request_id: attrs[:request_id],
            user_agent: attrs[:user_agent]
          },
          action: :record,
          authorize?: false,
          # AuditLog has no notifier. Returning the synthetic resource
          # notification avoids a false missed-notification warning when an
          # audited mutation is inside a caller-owned database transaction.
          return_notifications?: true
        )
        |> case do
          {:ok, _log, _notifications} ->
            :ok

          {:error, error} ->
            Logger.error("Alplus.Audit.write/1 failed: #{Exception.format(:error, error)}")
            :ok
        end
      end
    end
  end

  @doc """
  Latest allowed agent audit for the selected project.

  Optional `:transport` restricts to `remote_mcp` or `webmcp`. A credential
  row never satisfies this lookup.
  """
  @spec latest_allowed_agent_audit(Alplus.Scope.t(), String.t(), keyword()) ::
          {:ok, Alplus.Audit.AuditLog.t() | nil} | {:error, term()}
  def latest_allowed_agent_audit(%Alplus.Scope{} = scope, project_id, opts \\ [])
      when is_binary(project_id) and is_list(opts) do
    transport = Keyword.get(opts, :transport)

    query =
      Alplus.Audit.AuditLog
      |> Ash.Query.for_read(:read, %{}, actor: scope)
      |> Ash.Query.filter(
        org_id == ^scope.org_id and project_id == ^project_id and actor_kind == "agent" and
          outcome == "allowed" and transport in ["remote_mcp", "webmcp"]
      )
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(1)

    query =
      case transport do
        transport when transport in ["remote_mcp", "webmcp"] ->
          Ash.Query.filter(query, transport == ^transport)

        _ ->
          query
      end

    case Ash.read(query) do
      {:ok, [audit]} -> {:ok, audit}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @mcp_transports ["remote_mcp", "webmcp"]

  @doc """
  `true` when at least one agent has reached `project_id` over MCP.

  Deliberately policy-independent (`authorize?: false`): the `AuditLog`
  read policy only admits owners and admins, so an actor-scoped check
  would answer `false` for every member and lock members out of projects
  their agents already use. Safe because both ids are supplied by
  actor-scoped resolution upstream and the query is filtered by BOTH, so
  it can never observe another tenant's rows.

  Fails open (logging at error level): a broken existence check must
  never trap an operator outside their own project.
  """
  @spec agent_connected?(String.t(), String.t()) :: boolean()
  def agent_connected?(org_id, project_id) when is_binary(org_id) and is_binary(project_id) do
    query =
      Alplus.Audit.AuditLog
      |> Ash.Query.new()
      |> Ash.Query.filter(
        org_id == ^org_id and project_id == ^project_id and actor_kind == "agent" and
          outcome == "allowed" and transport in ^@mcp_transports
      )
      |> Ash.Query.select([:id])
      |> Ash.Query.limit(1)

    case Ash.read(query, authorize?: false, page: false) do
      {:ok, [_row]} ->
        true

      {:ok, []} ->
        false

      {:error, reason} ->
        Logger.error(
          "Alplus.Audit.agent_connected?/2 failed for project=#{project_id}: #{inspect(reason)}"
        )

        true
    end
  end

  @doc """
  Subset of `project_ids` that at least one agent has reached over MCP.

  One bounded query, never N+1, filtered by `org_id` AND the explicit id
  set. Policy-independent for the same reason as `agent_connected?/2`.
  """
  @spec agent_connected_project_ids(String.t(), [String.t()]) :: MapSet.t(String.t())
  def agent_connected_project_ids(org_id, project_ids)
      when is_binary(org_id) and is_list(project_ids) do
    case project_ids do
      [] ->
        MapSet.new()

      ids ->
        query =
          Alplus.Audit.AuditLog
          |> Ash.Query.new()
          |> Ash.Query.filter(
            org_id == ^org_id and actor_kind == "agent" and outcome == "allowed" and
              transport in ^@mcp_transports and project_id in ^ids
          )
          |> Ash.Query.select([:project_id])
          |> Ash.Query.distinct([:project_id])
          |> Ash.Query.limit(length(ids))

        case Ash.read(query, authorize?: false, page: false) do
          {:ok, rows} ->
            MapSet.new(rows, & &1.project_id)

          {:error, reason} ->
            Logger.error(
              "Alplus.Audit.agent_connected_project_ids/2 failed for org=#{org_id}: #{inspect(reason)}"
            )

            MapSet.new()
        end
    end
  end
end
