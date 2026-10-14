defmodule Alplus.Monitoring.ActiveCheckOutcome do
  @moduledoc false

  alias Alplus.Measure.PublicCache

  require Logger

  # The scheduler is an internal boundary, so this deliberately bypasses Ash
  # policies. One database transaction writes the immutable check, durable
  # counters, current monitor state, and any incident transition.
  @recovery_threshold 2

  @spec record(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def record(monitor_id, result) when is_binary(monitor_id) and is_map(result) do
    result =
      Alplus.Repo.transaction(fn ->
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
        monitor = lock_monitor!(monitor_id)
        ensure_runtime_state!(monitor, now)
        runtime = lock_runtime_state!(monitor_id)
        check_id = insert_check!(monitor, result, now)
        open_incident = lock_open_incident!(monitor)

        {failures, recoveries, incident, event} =
          transition!(monitor, runtime, open_incident, result, check_id, now)

        persist_status_draft_signal!(monitor, incident)
        enqueue_notification!(monitor, event, incident, failures)

        update_runtime!(
          monitor_id,
          monitor.config_version,
          failures,
          recoveries,
          result.status,
          now
        )

        update_monitor!(monitor_id, result.status, now)

        %{
          check_id: check_id,
          incident_id: incident && incident.id,
          org_id: monitor.org_id,
          project_id: monitor.project_id,
          status: result.status
        }
      end)

    case result do
      {:ok, %{project_id: project_id} = outcome} ->
        reconcile_status_draft_work(outcome)
        PublicCache.clear()

        Phoenix.PubSub.broadcast(
          Alplus.PubSub,
          "monitor:#{project_id}",
          {:monitor_updated, project_id}
        )

        {:ok, outcome}

      other ->
        other
    end
  end

  # Draft scheduling follows the committed Monitor transaction. A failed
  # ledger or Oban write must never erase a persisted check or incident.
  defp reconcile_status_draft_work(%{incident_id: nil}), do: :ok

  defp reconcile_status_draft_work(%{
         org_id: org_id,
         project_id: project_id,
         incident_id: incident_id
       }) do
    case Alplus.Status.IncidentDraftWorker.reconcile_for_incident(
           org_id,
           project_id,
           incident_id
         ) do
      {:ok, _jobs} -> :ok
      {:error, reason} -> Logger.error("incident draft reconciliation failed: #{inspect(reason)}")
    end
  end

  defp persist_status_draft_signal!(_monitor, nil), do: :ok

  defp persist_status_draft_signal!(monitor, %{id: incident_id}) do
    Alplus.Status.IncidentDraftWorker.persist_reconciliation_signal!(monitor, incident_id)
  end

  defp lock_monitor!(monitor_id) do
    %{rows: [row]} =
      Alplus.Repo.query!(
        """
        SELECT id, org_id, project_id, environment, failure_threshold, resend_after_failed_checks, config_version
        FROM monitors WHERE id = $1 AND status = 'active' FOR UPDATE
        """,
        [monitor_id]
      )

    [
      id,
      org_id,
      project_id,
      environment,
      failure_threshold,
      resend_after_failed_checks,
      config_version
    ] = row

    %{
      id: id,
      org_id: org_id,
      project_id: project_id,
      environment: environment,
      failure_threshold: failure_threshold,
      resend_after_failed_checks: resend_after_failed_checks,
      config_version: config_version
    }
  end

  defp ensure_runtime_state!(monitor, now) do
    Alplus.Repo.query!(
      """
      INSERT INTO active_monitor_runtime_states
        (monitor_id, config_version, consecutive_failures, consecutive_recoveries, last_status, inserted_at, updated_at)
      VALUES ($1, $2, 0, 0, 'unknown', $3, $3)
      ON CONFLICT (monitor_id) DO NOTHING
      """,
      [monitor.id, monitor.config_version, now]
    )
  end

  defp lock_runtime_state!(monitor_id) do
    %{rows: [row]} =
      Alplus.Repo.query!(
        """
        SELECT config_version, consecutive_failures, consecutive_recoveries
        FROM active_monitor_runtime_states WHERE monitor_id = $1 FOR UPDATE
        """,
        [monitor_id]
      )

    [config_version, failures, recoveries] = row
    %{config_version: config_version, failures: failures, recoveries: recoveries}
  end

  defp insert_check!(monitor, result, now) do
    check_id = Alplus.Id.generate(:monitor_check)

    Alplus.Repo.query!(
      """
      INSERT INTO monitor_checks
        (id, org_id, project_id, monitor_id, environment, status, status_code, latency_ms, error_class, checked_at, inserted_at)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$10)
      """,
      [
        check_id,
        monitor.org_id,
        monitor.project_id,
        monitor.id,
        monitor.environment,
        result.status,
        result.status_code,
        result.latency_ms,
        result.error_class,
        now
      ]
    )

    check_id
  end

  defp lock_open_incident!(monitor) do
    case Alplus.Repo.query!(
           """
           SELECT id, started_at
           FROM incidents
           WHERE monitor_id = $1 AND org_id = $2 AND project_id = $3 AND status = 'open'
           FOR UPDATE
           """,
           [monitor.id, monitor.org_id, monitor.project_id]
         ) do
      %{rows: [[id, started_at]]} -> %{id: id, started_at: to_utc_datetime(started_at)}
      %{rows: []} -> nil
    end
  end

  # `started_at` is a `:utc_datetime_usec` column, which Ecto stores as a bare
  # `timestamp` (UTC assumed). A raw `Repo.query!` bypasses Ecto's type layer,
  # so Postgrex hands the value back as a `NaiveDateTime`. `DateTime.diff/3`
  # rejects a naive argument, so coerce to a UTC `DateTime` at the boundary.
  defp to_utc_datetime(%DateTime{} = value), do: value
  defp to_utc_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

  defp transition!(monitor, runtime, open_incident, %{status: "down"} = result, check_id, now) do
    failures =
      if runtime.config_version == monitor.config_version, do: runtime.failures + 1, else: 1

    detail = %{"error_class" => result.error_class, "status_code" => result.status_code}

    incident =
      cond do
        open_incident ->
          Alplus.Repo.query!(
            "UPDATE incidents SET checks_failed_count = $2, cause_detail = $3::jsonb, updated_at = $4 WHERE id = $1",
            [open_incident.id, failures, detail, now]
          )

          open_incident

        failures >= monitor.failure_threshold ->
          incident_id = Alplus.Id.generate(:incident)

          Alplus.Repo.query!(
            """
            INSERT INTO incidents
              (id, org_id, project_id, monitor_id, environment, cause, cause_detail, triggering_check_id,
               started_at, checks_failed_count, status, inserted_at, updated_at)
            VALUES ($1,$2,$3,$4,$5,'availability',$6::jsonb,$7,$8,$9,'open',$8,$8)
            """,
            [
              incident_id,
              monitor.org_id,
              monitor.project_id,
              monitor.id,
              monitor.environment,
              detail,
              check_id,
              now,
              failures
            ]
          )

          %{id: incident_id, started_at: now}

        true ->
          nil
      end

    event =
      cond do
        open_incident && monitor.resend_after_failed_checks > 0 &&
            rem(failures, monitor.resend_after_failed_checks) == 0 ->
          :down

        not is_nil(incident) ->
          :down

        true ->
          nil
      end

    {failures, 0, incident, event}
  end

  defp transition!(_monitor, runtime, nil, %{status: status}, _check_id, _now) do
    # A non-down result clears a pending failure streak. Scheduler executors are
    # binary availability checks; degraded remains visible in check history.
    {0, if(status == "up", do: runtime.recoveries + 1, else: 0), nil, nil}
  end

  defp transition!(monitor, runtime, open_incident, %{status: "up"}, check_id, now) do
    recoveries =
      if runtime.config_version == monitor.config_version, do: runtime.recoveries + 1, else: 1

    incident =
      if recoveries >= @recovery_threshold do
        duration = max(DateTime.diff(now, open_incident.started_at, :second), 0)

        Alplus.Repo.query!(
          """
          UPDATE incidents
          SET status = 'resolved', resolved_at = $2, resolved_by_check_id = $3,
              duration_seconds = $4, updated_at = $2
          WHERE id = $1
          """,
          [open_incident.id, now, check_id, duration]
        )

        nil
      else
        open_incident
      end

    {0, recoveries, incident, if(is_nil(incident), do: :recovered, else: nil)}
  end

  defp transition!(_monitor, _runtime, open_incident, _result, _check_id, _now),
    do: {0, 0, open_incident, nil}

  defp enqueue_notification!(_monitor, nil, _incident, _failures), do: :ok

  defp enqueue_notification!(monitor, :down, %{id: incident_id}, failures) do
    Alplus.Notifications.MonitorRouter.enqueue!(monitor, "check_down", incident_id, failures)
  end

  defp enqueue_notification!(monitor, :recovered, _incident, _failures) do
    %{rows: [[incident_id]]} =
      Alplus.Repo.query!(
        """
        SELECT id
        FROM incidents
        WHERE monitor_id = $1 AND org_id = $2 AND project_id = $3
        ORDER BY resolved_at DESC
        LIMIT 1
        """,
        [monitor.id, monitor.org_id, monitor.project_id]
      )

    Alplus.Notifications.MonitorRouter.enqueue!(monitor, "check_recovered", incident_id, 0)
  end

  defp update_runtime!(monitor_id, config_version, failures, recoveries, status, now) do
    Alplus.Repo.query!(
      """
      UPDATE active_monitor_runtime_states
      SET config_version = $2, consecutive_failures = $3, consecutive_recoveries = $4,
          last_status = $5, last_check_at = $6, updated_at = $6
      WHERE monitor_id = $1
      """,
      [monitor_id, config_version, failures, recoveries, status, now]
    )
  end

  defp update_monitor!(monitor_id, status, now) do
    Alplus.Repo.query!(
      "UPDATE monitors SET last_known_status = $2, last_check_at = $3, updated_at = $3 WHERE id = $1",
      [monitor_id, status, now]
    )
  end
end
