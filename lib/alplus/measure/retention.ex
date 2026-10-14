defmodule Alplus.Measure.Retention do
  @moduledoc """
  Package-derived Measure rollup retention.

  These scoped bulk deletes are a documented direct PostgreSQL maintenance
  path. Ash should not load historical rollup rows merely to delete them.
  """

  alias Alplus.Billing.Package
  alias Alplus.Repo
  alias Alplus.Scope

  @spec retention_days() :: pos_integer()
  def retention_days, do: Package.limit(:measure_retention_days)

  @spec prune(Scope.t(), Date.t()) :: %{
          analytics_hours: non_neg_integer(),
          analytics_days: non_neg_integer(),
          analytics_dimensions: non_neg_integer(),
          goal_conversions: non_neg_integer(),
          cutoff: DateTime.t()
        }
  def prune(%Scope{org_id: org_id, project_id: project_id}, %Date{} = today)
      when is_binary(org_id) and is_binary(project_id) do
    cutoff =
      today
      |> Date.add(-retention_days())
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    %{num_rows: analytics_hours} =
      Repo.query!(
        """
        DELETE FROM analytics_hours
        WHERE org_id = $1 AND project_id = $2 AND hour < $3
        """,
        [org_id, project_id, cutoff]
      )

    cutoff_date = DateTime.to_date(cutoff)

    %{num_rows: analytics_days} =
      Repo.query!(
        """
        DELETE FROM analytics_days
        WHERE org_id = $1 AND project_id = $2 AND date < $3
        """,
        [org_id, project_id, cutoff_date]
      )

    %{num_rows: analytics_dimensions} =
      Repo.query!(
        """
        DELETE FROM analytics_dimensions
        WHERE org_id = $1 AND project_id = $2 AND date < $3
        """,
        [org_id, project_id, cutoff_date]
      )

    %{num_rows: goal_conversions} =
      Repo.query!(
        """
        DELETE FROM goal_conversions
        WHERE org_id = $1 AND project_id = $2 AND hour < $3
        """,
        [org_id, project_id, cutoff]
      )

    %{
      analytics_hours: analytics_hours,
      analytics_days: analytics_days,
      analytics_dimensions: analytics_dimensions,
      goal_conversions: goal_conversions,
      cutoff: cutoff
    }
  end
end
