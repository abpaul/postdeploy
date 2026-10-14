defmodule Alplus.Billing.DataPurgeObjectWorker do
  @moduledoc """
  Deletes one external Observe object after its database references disappear.

  The job rechecks the authoritative database immediately before deletion.
  A retry therefore cannot remove an object that a newly written row still
  references.
  """

  use Oban.Worker, queue: :default, max_attempts: 10

  alias Alplus.Observe.PayloadStore
  alias Alplus.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "key" => key,
          "kind" => kind,
          "org_id" => org_id,
          "project_id" => project_id
        }
      })
      when is_binary(key) and kind in ["events", "artifacts"] and is_binary(org_id) and
             is_binary(project_id) do
    cond do
      not scoped_key?(key, kind, org_id, project_id) ->
        {:cancel, {:invalid_object_scope, key}}

      referenced?(key, kind, org_id, project_id) ->
        {:snooze, 5}

      true ->
        case PayloadStore.delete(key) do
          :ok -> :ok
          {:error, reason} -> {:error, {:payload_delete_failed, key, reason}}
        end
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_object_delete_job}

  defp scoped_key?(key, kind, org_id, project_id) do
    String.starts_with?(key, "#{kind}/#{project_id}/") and
      project_belongs_to_org?(project_id, org_id)
  end

  defp referenced?(key, "events", org_id, project_id) do
    Repo.query!(
      """
      SELECT EXISTS(
        SELECT 1
        FROM error_events
        WHERE org_id = $1 AND project_id = $2 AND payload_s3_key = $3
      )
      """,
      [org_id, project_id, key]
    ).rows == [[true]]
  end

  defp referenced?(key, "artifacts", org_id, project_id) do
    Repo.query!(
      """
      SELECT EXISTS(
        SELECT 1
        FROM release_artifacts
        WHERE org_id = $1 AND project_id = $2 AND storage_key = $3
      )
      """,
      [org_id, project_id, key]
    ).rows == [[true]]
  end

  # The object key contains a globally unique project id, not an organization
  # id. Confirm ownership before the external delete.
  # sobelow_skip ["SQL.Query"]
  defp project_belongs_to_org?(project_id, org_id) do
    Repo.query!("SELECT 1 FROM projects WHERE id = $1 AND org_id = $2", [project_id, org_id]).rows ==
      [[1]]
  end
end
