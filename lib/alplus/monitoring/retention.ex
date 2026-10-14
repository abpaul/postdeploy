defmodule Alplus.Monitoring.Retention do
  @moduledoc """
  Package-derived Monitor history retention.

  This is a documented direct PostgreSQL escape hatch for bulk maintenance.
  It deliberately requires both organization and project ids and repeats both
  predicates in SQL. A daily Oban job must invoke it once for each scoped
  project; it must not run an unscoped tenant-wide delete.
  """

  alias Alplus.Billing.Package
  alias Alplus.Repo
  alias Alplus.Scope

  @doc "Returns the detailed check-history retention."
  @spec detailed_check_retention_days() :: pos_integer()
  def detailed_check_retention_days, do: Package.limit(:detailed_uptime_retention_days)

  @doc "Returns the durable incident-rollup retention."
  @spec incident_rollup_retention_months() :: pos_integer()
  def incident_rollup_retention_months, do: Package.limit(:uptime_incident_rollup_months)

  @doc """
  Deletes expired detailed monitor checks for one organization/project pair.

  Incident data remains untouched. It is the source of time-weighted uptime
  until daily rollups are available, so the rollup finalizer must archive it
  before a later maintenance action prunes it.
  """
  @spec prune_monitor_checks(Scope.t(), DateTime.t()) ::
          %{deleted: non_neg_integer(), cutoff: DateTime.t()}
  def prune_monitor_checks(%Scope{org_id: org_id, project_id: project_id}, %DateTime{} = now)
      when is_binary(org_id) and is_binary(project_id) do
    cutoff = DateTime.add(now, -detailed_check_retention_days(), :day)

    # Direct Ecto is justified here: this is a bulk maintenance delete, which
    # Ash cannot express without loading every history row (ARCHITECTURE.md §1b).
    result =
      Repo.query!(
        """
        DELETE FROM monitor_checks
        WHERE org_id = $1
          AND project_id = $2
          AND checked_at < $3
        """,
        [org_id, project_id, cutoff]
      )

    %{deleted: result.num_rows, cutoff: cutoff}
  end

  @doc "Deletes heartbeat idempotency claims whose retention window has elapsed."
  @spec prune_heartbeat_ping_deduplications(DateTime.t()) :: non_neg_integer()
  def prune_heartbeat_ping_deduplications(%DateTime{} = now) do
    %{num_rows: count} =
      Repo.query!(
        """
        DELETE FROM heartbeat_ping_deduplications
        WHERE expires_at <= $1
        """,
        [now]
      )

    count
  end
end
