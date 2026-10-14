defmodule Alplus.Observe.PayloadStorageWorker do
  @moduledoc """
  Uploads one persisted oversized Observe payload and then removes its outbox.

  The outbox is the source of truth until `PayloadStore.store_raw/2` returns
  `:ok`. Replaying a job is safe: object PUTs use the deterministic event key,
  and an already-removed row is treated as completed.
  """

  use Oban.Worker,
    queue: :telemetry,
    max_attempts: 10,
    unique: [
      period: {7, :days},
      keys: [:outbox_id],
      states: :incomplete
    ]

  alias Alplus.Observe.PayloadStore
  alias Alplus.Repo

  @replay_age_seconds 5 * 60
  @live_job_states ~w(available scheduled executing retryable suspended)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"outbox_id" => outbox_id}}) when is_binary(outbox_id) do
    case Repo.query(
           """
           SELECT event_received_at, event_id, project_id, payload_s3_key, payload
           FROM observe_error_payload_outboxes
           WHERE id = $1
           """,
           [outbox_id]
         ) do
      {:ok, %{rows: []}} ->
        :ok

      {:ok, %{rows: [[received_at, event_id, project_id, key, payload]]}} ->
        case PayloadStore.store_raw(key, payload) do
          :ok ->
            finalize_upload(outbox_id, received_at, event_id, project_id, key)

          {:error, reason} ->
            {:error, {:payload_store_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:outbox_lookup_failed, reason}}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_payload_storage_job}

  @doc """
  Re-enqueues outboxes older than the replay window when no live job owns them.

  Terminal jobs are intentionally ignored by the live-state query. Oban's
  incomplete uniqueness rule makes concurrent replays idempotent.
  """
  @spec replay_stranded(DateTime.t()) :: non_neg_integer()
  def replay_stranded(%DateTime{} = now) do
    cutoff = DateTime.add(now, -@replay_age_seconds, :second)

    stranded_outbox_ids(cutoff)
    |> Enum.count(fn [outbox_id] ->
      case Oban.insert(new(%{"outbox_id" => outbox_id})) do
        {:ok, %Oban.Job{conflict?: false}} -> true
        {:ok, %Oban.Job{}} -> false
        {:error, _reason} -> false
      end
    end)
  end

  def replay_stranded, do: replay_stranded(DateTime.utc_now())

  # sobelow_skip ["SQL.Query"]
  defp stranded_outbox_ids(cutoff) do
    Repo.query!(
      """
      SELECT o.id
      FROM observe_error_payload_outboxes AS o
      WHERE o.inserted_at < $1
        AND NOT EXISTS (
          SELECT 1
          FROM oban_jobs AS j
          WHERE j.worker = $2
            AND j.args ->> 'outbox_id' = o.id
            AND j.state = ANY($3)
        )
      """,
      [cutoff, Oban.Worker.to_string(__MODULE__), @live_job_states]
    ).rows
  end

  defp finalize_upload(outbox_id, received_at, event_id, project_id, key) do
    if event_references_object?(received_at, event_id, project_id, key) do
      delete_outbox(outbox_id)
      :ok
    else
      case PayloadStore.delete(key) do
        :ok ->
          delete_outbox(outbox_id)
          :ok

        {:error, reason} ->
          {:error, {:payload_delete_failed, key, reason}}
      end
    end
  end

  # sobelow_skip ["SQL.Query"]
  defp event_references_object?(received_at, event_id, project_id, key) do
    Repo.query!(
      """
      SELECT EXISTS(
        SELECT 1
        FROM error_events
        WHERE received_at = $1
          AND event_id = $2
          AND project_id = $3
          AND payload_s3_key = $4
      )
      """,
      [received_at, event_id, project_id, key]
    ).rows == [[true]]
  end

  defp delete_outbox(outbox_id) do
    Repo.query!("DELETE FROM observe_error_payload_outboxes WHERE id = $1", [outbox_id])
    :ok
  end
end
