defmodule Alplus.Monitoring.Monitor.Changes.RecordPauseInterval do
  @moduledoc false

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    previous_status = changeset.data.status
    next_status = Ash.Changeset.get_attribute(changeset, :status)

    Ash.Changeset.after_action(changeset, fn _changeset, monitor ->
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      case {previous_status, next_status} do
        {"active", "paused"} ->
          Alplus.Repo.query!(
            """
            INSERT INTO monitor_pause_intervals
              (id, org_id, project_id, monitor_id, paused_at, inserted_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $5, $5)
            """,
            [
              Alplus.Id.generate(:monitor_pause_interval),
              monitor.org_id,
              monitor.project_id,
              monitor.id,
              now
            ]
          )

        {"paused", "active"} ->
          Alplus.Repo.query!(
            """
            UPDATE monitor_pause_intervals
            SET resumed_at = $4, updated_at = $4
            WHERE org_id = $1 AND project_id = $2 AND monitor_id = $3 AND resumed_at IS NULL
            """,
            [monitor.org_id, monitor.project_id, monitor.id, now]
          )

        _ ->
          :ok
      end

      {:ok, monitor}
    end)
  end
end
