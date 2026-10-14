defmodule Alplus.Observe.Retention do
  @moduledoc """
  Package retention for Observe events and release artifacts.

  Event rows and artifact references are deleted in one transaction. External
  object jobs are inserted after the references disappear, before the
  transaction commits.
  """

  alias Alplus.Billing.Package
  alias Alplus.Repo

  @spec event_retention_days() :: pos_integer()
  def event_retention_days, do: Package.limit(:error_event_retention_days)

  @spec artifact_retention_days() :: pos_integer()
  def artifact_retention_days, do: Package.limit(:artifact_retention_days)

  @doc """
  Deletes expired Observe rows for one organization.

  The return value remains the number of deleted event rows for compatibility
  with the existing maintenance worker. Artifact rows and deduplication guards
  are pruned in the same transaction.
  """
  @spec prune(String.t(), DateTime.t()) :: non_neg_integer()
  def prune(org_id, %DateTime{} = now) when is_binary(org_id) do
    event_cutoff = DateTime.add(now, -event_retention_days(), :day)
    artifact_cutoff = DateTime.add(now, -artifact_retention_days(), :day)

    {:ok, deleted_events} =
      Repo.transaction(fn ->
        objects = expired_objects(org_id, event_cutoff, artifact_cutoff)

        deleted_events =
          Repo.query!(
            """
            DELETE FROM error_events
            WHERE org_id = $1 AND received_at < $2
            """,
            [org_id, event_cutoff]
          ).num_rows

        Repo.query!(
          """
          DELETE FROM error_event_deduplications
          WHERE org_id = $1 AND received_at < $2
          """,
          [org_id, event_cutoff]
        )

        Repo.query!(
          """
          DELETE FROM release_artifacts
          WHERE org_id = $1 AND inserted_at < $2
          """,
          [org_id, artifact_cutoff]
        )

        # Keep the reference deletion and job insertion in one transaction.
        # Oban publishes jobs only after commit, when the references are gone.
        enqueue_object_deletes(objects)
        deleted_events
      end)

    deleted_events
  end

  # The object list is read before either database reference is deleted. The
  # worker receives only identifiers and performs a second reference check.
  # sobelow_skip ["SQL.Query"]
  defp expired_objects(org_id, event_cutoff, artifact_cutoff) do
    Repo.query!(
      """
      SELECT payload_s3_key, project_id, 'events'
      FROM error_events
      WHERE org_id = $1
        AND received_at < $2
        AND payload_s3_key IS NOT NULL
      UNION ALL
      SELECT storage_key, project_id, 'artifacts'
      FROM release_artifacts
      WHERE org_id = $1
        AND inserted_at < $3
      """,
      [org_id, event_cutoff, artifact_cutoff]
    ).rows
    |> Enum.uniq()
    |> Enum.map(fn [key, project_id, kind] ->
      %{key: key, kind: kind, org_id: org_id, project_id: project_id}
    end)
  end

  defp enqueue_object_deletes(objects) do
    Enum.each(objects, fn args ->
      args
      |> Alplus.Billing.DataPurgeObjectWorker.new()
      |> Oban.insert!()
    end)
  end

  # 24h window, matching every other idempotency key (ARCHITECTURE.md
  # §13). Global, not org-scoped: the session id is discarded after rollup.
  @spec prune_session_dedup(DateTime.t()) :: non_neg_integer()
  def prune_session_dedup(%DateTime{} = now) do
    cutoff = DateTime.add(now, -86_400, :second)

    %{num_rows: count} =
      Repo.query!("DELETE FROM observe_session_deduplications WHERE received_at < $1", [cutoff])

    count
  end
end
