defmodule Alplus.Status.MaintenanceWorker do
  @moduledoc "Starts and finishes announced maintenance through Monitor actions."
  use Oban.Worker, queue: :telemetry, max_attempts: 3
  alias Alplus.Repo
  alias Alplus.Status.ScheduledMaintenance

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: run()

  def run do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    with :ok <- activate_due(now), do: complete_due(now)
  end

  @doc """
  Cancels one window, resuming any monitor this window had paused.

  The status flips to "cancelled" before the monitors are resumed, so
  `active_maintenance?/4` no longer counts this window as covering them. The
  scheduler self-excludes by time instead, because a completing window's
  `ends_at` has already passed; a cancelled window's has not.
  """
  def cancel(%ScheduledMaintenance{} = maintenance) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    %{id: id, org_id: org_id, project_id: project_id} = maintenance

    result =
      transaction(fn ->
        locked = lock_maintenance!(id, org_id, project_id, maintenance.status)
        rows = monitor_rows(id, org_id, project_id)
        notifications = update_maintenance!(locked, :cancel)

        notifications ++
          Enum.flat_map(rows, &resume_monitor!(&1, id, org_id, project_id, now))
      end)

    case result do
      :ok ->
        Alplus.Measure.PublicCache.clear()

        Phoenix.PubSub.broadcast(
          Alplus.PubSub,
          "monitor:#{project_id}",
          {:monitor_updated, project_id}
        )

        :ok

      other ->
        other
    end
  end

  defp activate_due(now) do
    # This scheduler query claims due windows in one batch before row locks.
    rows =
      Repo.query!(
        """
        SELECT id, org_id, project_id FROM status_scheduled_maintenances
        WHERE status = 'scheduled' AND starts_at <= $1 AND ends_at > $1
        """,
        [now]
      ).rows

    transition_many(rows, &transition_start(elem(&1, 0), elem(&1, 1), elem(&1, 2)))
  end

  defp complete_due(now) do
    # This scheduler query finds only active windows whose end time passed.
    rows =
      Repo.query!(
        """
        SELECT id, org_id, project_id FROM status_scheduled_maintenances
        WHERE status = 'active' AND ends_at <= $1
        """,
        [now]
      ).rows

    transition_many(rows, &transition_end(elem(&1, 0), elem(&1, 1), elem(&1, 2), now))
  end

  defp transition_many(rows, fun) do
    Enum.reduce_while(rows, :ok, fn [id, org_id, project_id], :ok ->
      case fun.({id, org_id, project_id}) do
        :ok ->
          Alplus.Measure.PublicCache.clear()

          Phoenix.PubSub.broadcast(
            Alplus.PubSub,
            "monitor:#{project_id}",
            {:monitor_updated, project_id}
          )

          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp transition_start(id, org_id, project_id) do
    transaction(fn ->
      maintenance = lock_maintenance!(id, org_id, project_id, "scheduled")

      monitor_notifications =
        monitor_rows(id, org_id, project_id)
        |> Enum.flat_map(&pause_monitor!(&1, id, org_id, project_id))

      monitor_notifications ++ update_maintenance!(maintenance, :activate)
    end)
  end

  defp transition_end(id, org_id, project_id, now) do
    transaction(fn ->
      maintenance = lock_maintenance!(id, org_id, project_id, "active")

      monitor_notifications =
        monitor_rows(id, org_id, project_id)
        |> Enum.flat_map(&resume_monitor!(&1, id, org_id, project_id, now))

      monitor_notifications ++ update_maintenance!(maintenance, :complete)
    end)
  end

  defp transaction(fun) do
    # Monitor status and maintenance transitions must commit as one unit.
    case Repo.transaction(fun) do
      {:ok, notifications} ->
        Ash.Notifier.notify(notifications)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lock_maintenance!(id, org_id, project_id, status) do
    # Lock the tenant-scoped row so two Oban retries cannot transition it twice.
    case Repo.query!(
           """
           SELECT id FROM status_scheduled_maintenances
           WHERE id = $1 AND org_id = $2 AND project_id = $3 AND status = $4 FOR UPDATE
           """,
           [id, org_id, project_id, status]
         ).rows do
      [[^id]] ->
        case Ash.get(ScheduledMaintenance, id, authorize?: false) do
          {:ok, maintenance} -> maintenance
          {:error, error} -> Repo.rollback({:maintenance_missing, error})
        end

      _ ->
        Repo.rollback(:maintenance_not_due)
    end
  end

  defp monitor_rows(maintenance_id, org_id, project_id) do
    # Read and lock only join rows and monitors from this tenant.
    Repo.query!(
      """
      SELECT mm.monitor_id, mm.paused_by_maintenance, m.status
      FROM status_maintenance_monitors AS mm
      INNER JOIN monitors AS m
        ON m.id = mm.monitor_id AND m.org_id = $2 AND m.project_id = $3
      WHERE mm.maintenance_id = $1 AND mm.org_id = $2 AND mm.project_id = $3 FOR UPDATE OF mm, m
      """,
      [maintenance_id, org_id, project_id]
    ).rows
  end

  defp pause_monitor!([monitor_id, _owned, "paused"], maintenance_id, org_id, project_id) do
    if pause_owned_by_active_maintenance?(maintenance_id, monitor_id, org_id, project_id) do
      mark_pause_owner!(maintenance_id, monitor_id, org_id, project_id)
    end

    []
  end

  defp pause_monitor!([monitor_id, _owned, "active"], maintenance_id, org_id, project_id) do
    notifications = update_monitor!(monitor_id, org_id, project_id, "paused")

    # The join tracks whether this maintenance paused the monitor.
    mark_pause_owner!(maintenance_id, monitor_id, org_id, project_id)

    notifications
  end

  defp pause_monitor!([monitor_id, _owned, _], _maintenance_id, _org_id, _project_id),
    do: Repo.rollback({:monitor_not_active, monitor_id})

  defp mark_pause_owner!(maintenance_id, monitor_id, org_id, project_id) do
    Repo.query!(
      "UPDATE status_maintenance_monitors SET paused_by_maintenance = true WHERE maintenance_id = $1 AND monitor_id = $2 AND org_id = $3 AND project_id = $4",
      [maintenance_id, monitor_id, org_id, project_id]
    )
  end

  defp pause_owned_by_active_maintenance?(maintenance_id, monitor_id, org_id, project_id) do
    case Repo.query(
           """
           SELECT 1
           FROM status_maintenance_monitors AS mm
           INNER JOIN status_scheduled_maintenances AS m
             ON m.id = mm.maintenance_id
            AND m.org_id = $2
            AND m.project_id = $3
           WHERE mm.maintenance_id <> $1
             AND mm.monitor_id = $4
             AND mm.org_id = $2
             AND mm.project_id = $3
             AND mm.paused_by_maintenance = true
             AND m.status = 'active'
           LIMIT 1
           """,
           [maintenance_id, org_id, project_id, monitor_id]
         ) do
      {:ok, %{rows: [_ | _]}} -> true
      _ -> false
    end
  end

  defp resume_monitor!([monitor_id, true, _], maintenance_id, org_id, project_id, now) do
    notifications =
      if active_maintenance?(org_id, project_id, monitor_id, now),
        do: [],
        else: update_monitor!(monitor_id, org_id, project_id, "active")

    # Clear ownership only after the monitor transition succeeds.
    Repo.query!(
      "UPDATE status_maintenance_monitors SET paused_by_maintenance = false WHERE maintenance_id = $1 AND monitor_id = $2 AND org_id = $3 AND project_id = $4",
      [maintenance_id, monitor_id, org_id, project_id]
    )

    notifications
  end

  defp resume_monitor!(_, _maintenance_id, _org_id, _project_id, _now), do: []

  defp update_monitor!(monitor_id, org_id, project_id, status) do
    with {:ok, monitor} <- Ash.get(Alplus.Monitoring.Monitor, monitor_id, authorize?: false),
         true <- monitor.org_id == org_id and monitor.project_id == project_id,
         {:ok, _monitor, notifications} <-
           Ash.update(monitor, %{status: status},
             action: :update,
             authorize?: false,
             context: %{warn_on_transaction_hooks?: false},
             return_notifications?: true
           ) do
      notifications
    else
      {:error, error} -> Repo.rollback({:monitor_update_failed, monitor_id, error})
      _ -> Repo.rollback({:monitor_scope_failed, monitor_id})
    end
  end

  defp update_maintenance!(maintenance, action) do
    case Ash.update(maintenance, %{},
           action: action,
           authorize?: false,
           return_notifications?: true
         ) do
      {:ok, _maintenance, notifications} -> notifications
      {:error, error} -> Repo.rollback({:maintenance_update_failed, error})
    end
  end

  defp active_maintenance?(org_id, project_id, monitor_id, now) do
    # Count overlapping active windows to preserve pauses owned by another window.
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM status_maintenance_monitors AS mm
        INNER JOIN status_scheduled_maintenances AS m
          ON m.id = mm.maintenance_id AND m.org_id = $1 AND m.project_id = $2
        WHERE mm.org_id = $1 AND mm.project_id = $2 AND mm.monitor_id = $3
          AND m.status = 'active' AND m.starts_at <= $4 AND m.ends_at > $4
        """,
        [org_id, project_id, monitor_id, now]
      )

    count > 0
  end
end
