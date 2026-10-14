defmodule Alplus.Monitoring.Heartbeat do
  @moduledoc """
  Hot heartbeat persistence boundary.

  This direct SQL path is an ARCHITECTURE.md §8 exception. It locks the
  per-monitor runtime row, writes the check and incident transition, and
  updates monitor state in one Postgres transaction.
  """

  alias Alplus.Billing.{Access, EntitlementError}
  alias Alplus.Measure.PublicCache
  alias Alplus.Monitoring.{HeartbeatConfig, Monitor}

  require Logger

  @type state :: :start | :finish | :fail

  @spec accept(String.t(), state()) :: :unknown | :paused | :accepted
  def accept(token, state) when state in [:start, :finish, :fail],
    do: accept(token, state, nil)

  @doc "Records an optional idempotent heartbeat ping for a token."
  @spec accept(String.t(), state(), String.t() | nil) :: :unknown | :paused | :accepted
  def accept(token, state, ping_id) when state in [:start, :finish, :fail] do
    case authenticated_config(token) do
      {:ok, %HeartbeatConfig{monitor: %Monitor{type: "heartbeat"} = monitor} = config} ->
        accept_config(config, monitor, state, ping_id)

      _ ->
        :unknown
    end
  end

  def accept(_token, _state, _ping_id), do: :unknown

  @doc "Records a heartbeat for an already authenticated, project-scoped monitor."
  @spec accept_for_monitor(Monitor.t(), state()) :: :unknown | :paused | :accepted
  def accept_for_monitor(%Monitor{type: "heartbeat"} = monitor, state)
      when state in [:start, :finish, :fail],
      do: accept_for_monitor(monitor, state, nil)

  @doc "Records an optional idempotent heartbeat for an authenticated monitor."
  @spec accept_for_monitor(Monitor.t(), state(), String.t() | nil) ::
          :unknown | :paused | :accepted
  def accept_for_monitor(%Monitor{type: "heartbeat"} = monitor, state, ping_id)
      when state in [:start, :finish, :fail] do
    case monitor.heartbeat_config do
      %HeartbeatConfig{} = config ->
        accept_config(config, monitor, state, ping_id)

      _ ->
        :unknown
    end
  end

  def accept_for_monitor(_monitor, _state, _ping_id), do: :unknown

  defp accept_config(%HeartbeatConfig{} = config, %Monitor{} = monitor, state, ping_id) do
    with :ok <- active?(monitor),
         {:ok, _access} <- Access.check(monitor.org_id) do
      case persist(config, monitor, state, ping_id) do
        {:ok, :duplicate} ->
          :accepted

        {:ok, {:persisted, incident_ids}} ->
          Enum.each(incident_ids, &reconcile_status_draft_work(monitor, &1))

          PublicCache.clear()

          Phoenix.PubSub.broadcast(
            Alplus.PubSub,
            "monitor:#{monitor.project_id}",
            {:monitor_updated, monitor.project_id}
          )

          :accepted

        {:error, reason} ->
          Logger.error("heartbeat persistence failed: #{inspect(reason)}")
          :unknown
      end
    else
      {:error, %EntitlementError{reason: :plan_inactive}} -> :paused
      {:error, :paused} -> :paused
      _error -> :unknown
    end
  end

  defp active?(%Monitor{status: "paused"}), do: {:error, :paused}
  defp active?(%Monitor{}), do: :ok

  defp authenticated_config(token) do
    case HeartbeatConfig.authenticate(token) do
      {:ok, config} -> {:ok, Ash.load!(config, :monitor, authorize?: false)}
      error -> error
    end
  end

  defp persist(%HeartbeatConfig{} = config, %Monitor{} = monitor, state, ping_id) do
    now = DateTime.utc_now()

    Alplus.Repo.transaction(fn ->
      runtime = lock_runtime_state(monitor.id, now)

      case claim_ping(monitor.id, ping_id, now) do
        :duplicate ->
          :duplicate

        :claimed ->
          {runtime, hung_incident_id} = record_hung_if_needed(config, monitor, runtime, now)

          incident_ids =
            case state do
              :start ->
                persist_start(monitor, runtime, now)
                [hung_incident_id]

              :finish ->
                persist_pass(monitor, runtime, now)
                [hung_incident_id]

              :fail ->
                [hung_incident_id, persist_explicit_failure(monitor, runtime, now)]
            end

          incident_ids = Enum.reject(incident_ids, &is_nil/1)
          Enum.each(incident_ids, &persist_status_draft_signal!(monitor, &1))
          {:persisted, incident_ids}
      end
    end)
  end

  defp claim_ping(_monitor_id, nil, _now), do: :claimed

  defp claim_ping(monitor_id, ping_id, now) when is_binary(ping_id) do
    claimed_at = DateTime.to_naive(now)
    expires_at = NaiveDateTime.add(claimed_at, 24, :hour)

    %{rows: rows} =
      Alplus.Repo.query!(
        """
        INSERT INTO heartbeat_ping_deduplications (monitor_id, ping_id, expires_at)
        VALUES ($1, $2, $4)
        ON CONFLICT (monitor_id, ping_id) DO UPDATE
          SET expires_at = EXCLUDED.expires_at
          WHERE heartbeat_ping_deduplications.expires_at <= $3
        RETURNING monitor_id
        """,
        [monitor_id, ping_id, claimed_at, expires_at]
      )

    if rows == [], do: :duplicate, else: :claimed
  end

  defp claim_ping(_monitor_id, _ping_id, _now), do: :claimed

  defp lock_runtime_state(monitor_id, now) do
    Alplus.Repo.query!(
      """
      INSERT INTO heartbeat_runtime_states
        (monitor_id, consecutive_failures, consecutive_passes, inserted_at, updated_at)
      VALUES ($1, 0, 0, $2, $2)
      ON CONFLICT (monitor_id) DO NOTHING
      """,
      [monitor_id, now]
    )

    %{rows: [[pending_start_at, _last_heartbeat_at, failures, passes]]} =
      Alplus.Repo.query!(
        """
        SELECT pending_start_at, last_heartbeat_at, consecutive_failures, consecutive_passes
        FROM heartbeat_runtime_states WHERE monitor_id = $1 FOR UPDATE
        """,
        [monitor_id]
      )

    %{pending_start_at: to_utc_datetime(pending_start_at), failures: failures, passes: passes}
  end

  # `pending_start_at` is a `:utc_datetime_usec` column, which Ecto stores as
  # a bare `timestamp` (UTC assumed). A raw `Repo.query!` bypasses Ecto's
  # type layer, so Postgrex hands the value back as a `NaiveDateTime`.
  # `DateTime.diff/3` rejects a naive argument, so coerce at the boundary.
  defp to_utc_datetime(nil), do: nil
  defp to_utc_datetime(%DateTime{} = value), do: value
  defp to_utc_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

  defp record_hung_if_needed(
         %HeartbeatConfig{expected_duration_seconds: nil},
         _monitor,
         runtime,
         _now
       ),
       do: {runtime, nil}

  defp record_hung_if_needed(%HeartbeatConfig{} = config, monitor, runtime, now) do
    if runtime.pending_start_at &&
         DateTime.diff(now, runtime.pending_start_at, :second) >
           2 * config.expected_duration_seconds do
      failures = runtime.failures + 1
      check_id = record_check(monitor, "down", "heartbeat_hung", now)
      update_runtime(monitor.id, nil, now, failures, 0, now)

      incident_id =
        if failures >= monitor.failure_threshold do
          update_monitor(monitor, "down", now)
          incident_id = upsert_open_incident(monitor, check_id, now)

          Alplus.Notifications.MonitorRouter.enqueue!(
            monitor,
            "check_down",
            incident_id,
            failures
          )

          incident_id
        end

      {%{runtime | pending_start_at: nil, failures: failures, passes: 0},
       if(failures >= monitor.failure_threshold, do: incident_id, else: nil)}
    else
      {runtime, nil}
    end
  end

  # A `start` ping only records that a run began. It must not clear the
  # consecutive failure/pass counters: a hung-detection bump earlier in the
  # same request (`record_hung_if_needed`) must survive this call, and an
  # in-progress pass streak must not be reset just because a new run started.
  defp persist_start(monitor, runtime, now) do
    update_runtime(monitor.id, now, now, runtime.failures, runtime.passes, now)
  end

  defp persist_pass(monitor, runtime, now) do
    check_id = record_check(monitor, "up", nil, now)
    passes = runtime.passes + 1
    update_runtime(monitor.id, nil, now, 0, passes, now)
    update_monitor(monitor, "up", now)

    if passes >= 2 do
      case resolve_open_incident(monitor, check_id, now) do
        incident_id when is_binary(incident_id) ->
          Alplus.Notifications.MonitorRouter.enqueue!(monitor, "check_recovered", incident_id, 0)

        nil ->
          :ok
      end
    end
  end

  defp persist_explicit_failure(monitor, runtime, now) do
    check_id = record_check(monitor, "down", "heartbeat_fail", now)
    failures = runtime.failures + 1
    update_runtime(monitor.id, nil, now, failures, 0, now)
    update_monitor(monitor, "down", now)
    incident_id = upsert_open_incident(monitor, check_id, now)
    Alplus.Notifications.MonitorRouter.enqueue!(monitor, "check_down", incident_id, failures)
    incident_id
  end

  defp record_check(monitor, status, error_class, now) do
    check_id = Alplus.Id.generate(:monitor_check)

    Alplus.Repo.query!(
      """
      INSERT INTO monitor_checks
        (id, org_id, project_id, monitor_id, environment, status, error_class, checked_at, inserted_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $8)
      """,
      [
        check_id,
        monitor.org_id,
        monitor.project_id,
        monitor.id,
        monitor.environment,
        status,
        error_class,
        now
      ]
    )

    check_id
  end

  defp update_runtime(monitor_id, pending_start_at, last_heartbeat_at, failures, passes, now) do
    Alplus.Repo.query!(
      """
      UPDATE heartbeat_runtime_states
      SET pending_start_at = $2, last_heartbeat_at = $3, consecutive_failures = $4,
          consecutive_passes = $5, updated_at = $6
      WHERE monitor_id = $1
      """,
      [monitor_id, pending_start_at, last_heartbeat_at, failures, passes, now]
    )
  end

  defp update_monitor(monitor, status, now) do
    Alplus.Repo.query!(
      """
      UPDATE monitors
      SET last_known_status = $4, last_check_at = $5, updated_at = $5
      WHERE id = $1 AND org_id = $2 AND project_id = $3
      """,
      [monitor.id, monitor.org_id, monitor.project_id, status, now]
    )
  end

  defp upsert_open_incident(monitor, check_id, now) do
    %{rows: [[incident_id]]} =
      Alplus.Repo.query!(
        """
        INSERT INTO incidents
          (id, org_id, project_id, monitor_id, environment, status, cause, cause_detail,
           triggering_check_id, started_at, checks_failed_count, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, 'open', 'heartbeat', '{}', $6, $7, 1, $7, $7)
        ON CONFLICT (monitor_id) WHERE status = 'open'
        DO UPDATE SET checks_failed_count = incidents.checks_failed_count + 1, updated_at = EXCLUDED.updated_at
        RETURNING id
        """,
        [
          Alplus.Id.generate(:incident),
          monitor.org_id,
          monitor.project_id,
          monitor.id,
          monitor.environment,
          check_id,
          now
        ]
      )

    incident_id
  end

  # Draft scheduling follows the committed heartbeat transaction. A failed
  # ledger or Oban write must never erase a heartbeat incident.
  defp reconcile_status_draft_work(monitor, incident_id) do
    case Alplus.Status.IncidentDraftWorker.reconcile_for_incident(
           monitor.org_id,
           monitor.project_id,
           incident_id
         ) do
      {:ok, _jobs} -> :ok
      {:error, reason} -> Logger.error("incident draft reconciliation failed: #{inspect(reason)}")
    end
  end

  defp persist_status_draft_signal!(monitor, incident_id) do
    Alplus.Status.IncidentDraftWorker.persist_reconciliation_signal!(monitor, incident_id)
  end

  defp resolve_open_incident(monitor, check_id, now) do
    case Alplus.Repo.query!(
           """
           UPDATE incidents
           SET status = 'resolved', resolved_at = $4, resolved_by_check_id = $5,
               duration_seconds = GREATEST(0, EXTRACT(EPOCH FROM ($4 - started_at))::bigint), updated_at = $4
           WHERE monitor_id = $1 AND org_id = $2 AND project_id = $3 AND status = 'open'
           RETURNING id
           """,
           [monitor.id, monitor.org_id, monitor.project_id, now, check_id]
         ) do
      %{rows: [[incident_id]]} -> incident_id
      %{rows: []} -> nil
    end
  end
end
