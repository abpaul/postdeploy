defmodule Alplus.ConcurrencyCase do
  @moduledoc """
  Case template for races that need real, concurrent PostgreSQL connections.

  Warning: these tests run OUTSIDE the Ecto sandbox and commit real rows.
  The sandbox hands every process one shared connection inside one
  transaction, so a `FOR UPDATE` row lock never contends there: a sandboxed
  test cannot observe the bug these tests exist to catch. Each test deletes
  the rows it committed in `on_exit`.
  """

  use ExUnit.CaseTemplate

  @lock_wait_timeout_ms 20_000

  using do
    quote do
      import Alplus.ConcurrencyCase
      import Alplus.OrgsFixtures
    end
  end

  setup do
    checkout_committing_connection()
    Alplus.DataCase.stub_external_clients()
    :ok
  end

  @doc "Checks out a connection that no sandbox transaction wraps."
  def checkout_committing_connection do
    Ecto.Adapters.SQL.Sandbox.checkout(Alplus.Repo, sandbox: false)
  end

  @doc """
  Runs `fun` in `count` processes that all contend for the same organization
  row lock, then releases them together. Returns their results in order.

  Warning: a plain "start together" barrier proves nothing. One caller can
  finish its whole transaction before the other opens one, and broken locking
  still passes. This holds the organization row lock from a separate
  connection until every caller is parked on that same lock inside its own
  transaction. Each caller's capacity count is then guaranteed to run after
  the previous caller committed, which is exactly the ordering the gate must
  survive.

  Pass `:while_parked` to run a function after every caller is parked and
  before the lock is released. That is the only window in which a test can
  change the world a blocked transaction will see when it wakes.
  """
  def race_for_org(org_id, count, fun, opts \\ []) do
    parent = self()
    holder = start_lock_holder(org_id)

    tasks =
      Enum.map(1..count, fn index ->
        Task.async(fn ->
          checkout_committing_connection()
          send(parent, {:racer_ready, backend_pid()})

          receive do
            :go -> :ok
          after
            @lock_wait_timeout_ms -> raise "the race never started"
          end

          fun.(index)
        end)
      end)

    backend_pids = Enum.map(tasks, fn _task -> await_ready() end)
    Enum.each(tasks, fn task -> send(task.pid, :go) end)

    await_all_blocked_on_lock(backend_pids)

    case Keyword.get(opts, :while_parked) do
      nil -> :ok
      while_parked -> while_parked.()
    end

    release_lock_holder(holder)

    Task.await_many(tasks, 30_000)
  end

  @doc """
  Runs callers after they contend on one organization's usage-period row.

  The event meter locks `usage_periods`, not `organizations`, so parking the
  callers on the organization row would prove nothing about the ceiling: both
  would read the same pre-count and both would accept a full batch.
  """
  def race_for_usage_period(org_id, period_start, count, fun) do
    parent = self()
    holder = start_usage_period_lock_holder(org_id, period_start)

    tasks =
      Enum.map(1..count, fn index ->
        Task.async(fn ->
          checkout_committing_connection()
          send(parent, {:racer_ready, backend_pid()})

          receive do
            :go -> fun.(index)
          after
            @lock_wait_timeout_ms -> raise "the usage-period race never started"
          end
        end)
      end)

    backend_pids = Enum.map(tasks, fn _task -> await_ready() end)
    Enum.each(tasks, fn task -> send(task.pid, :go) end)
    await_all_blocked_on_lock(backend_pids)
    release_lock_holder(holder)
    Task.await_many(tasks, 30_000)
  end

  @doc "Runs callers after they contend on one durable incident-draft workflow row."
  def race_for_workflow(workflow_id, count, fun) do
    parent = self()
    holder = start_workflow_lock_holder(workflow_id)

    tasks =
      Enum.map(1..count, fn index ->
        Task.async(fn ->
          checkout_committing_connection()
          send(parent, {:racer_ready, backend_pid()})

          receive do
            :go -> fun.(index)
          after
            @lock_wait_timeout_ms -> raise "the workflow race never started"
          end
        end)
      end)

    backend_pids = Enum.map(tasks, fn _task -> await_ready() end)
    Enum.each(tasks, fn task -> send(task.pid, :go) end)
    await_all_blocked_on_lock(backend_pids)
    release_lock_holder(holder)
    Task.await_many(tasks, 30_000)
  end

  @doc """
  Deletes the rows this test committed. The organization cascades to the
  org-scoped tables; `notification_deliveries` restricts that delete, and
  user rows outlive the organization, so both are named here.

  Warning: every monitor stops first. A monitor worker outlives the row it
  checks, and an orphan worker logs "monitor config load failed" into
  whatever test runs next.
  """
  def delete_after_test(org_ids, user_ids) do
    ExUnit.Callbacks.on_exit(fn ->
      checkout_committing_connection()
      Enum.each(org_ids, &stop_monitors/1)

      Alplus.Repo.query!("DELETE FROM notification_deliveries WHERE org_id = ANY($1::text[])", [
        org_ids
      ])

      Alplus.Repo.query!("DELETE FROM organizations WHERE id = ANY($1::text[])", [org_ids])
      Alplus.Repo.query!("DELETE FROM users WHERE id = ANY($1::text[])", [user_ids])
    end)
  end

  defp stop_monitors(org_id) do
    %{rows: rows} = Alplus.Repo.query!("SELECT id FROM monitors WHERE org_id = $1", [org_id])
    Enum.each(rows, fn [monitor_id] -> Alplus.Monitoring.Scheduler.stop_monitor(monitor_id) end)
  end

  defp backend_pid do
    %{rows: [[pid]]} = Alplus.Repo.query!("SELECT pg_backend_pid()", [])
    pid
  end

  defp start_lock_holder(org_id) do
    parent = self()

    pid =
      spawn_link(fn ->
        checkout_committing_connection()

        Alplus.Repo.transaction(fn ->
          Alplus.Repo.query!("SELECT id FROM organizations WHERE id = $1 FOR UPDATE", [org_id])
          send(parent, {:lock_held, self()})

          receive do
            :release -> :ok
          after
            @lock_wait_timeout_ms -> :ok
          end
        end)
      end)

    receive do
      {:lock_held, ^pid} -> pid
    after
      @lock_wait_timeout_ms -> raise "the lock holder never took the organization row lock"
    end
  end

  defp start_usage_period_lock_holder(org_id, period_start) do
    parent = self()

    pid =
      spawn_link(fn ->
        checkout_committing_connection()

        Alplus.Repo.transaction(fn ->
          Alplus.Repo.query!(
            "SELECT id FROM usage_periods WHERE org_id = $1 AND period_start = $2 FOR UPDATE",
            [org_id, period_start]
          )

          send(parent, {:lock_held, self()})

          receive do
            :release -> :ok
          after
            @lock_wait_timeout_ms -> :ok
          end
        end)
      end)

    receive do
      {:lock_held, ^pid} -> pid
    after
      @lock_wait_timeout_ms -> raise "the lock holder never took the usage-period row lock"
    end
  end

  defp start_workflow_lock_holder(workflow_id) do
    parent = self()

    pid =
      spawn_link(fn ->
        checkout_committing_connection()

        Alplus.Repo.transaction(fn ->
          Alplus.Repo.query!(
            "SELECT id FROM monitor_incident_status_draft_workflows WHERE id = $1 FOR UPDATE",
            [workflow_id]
          )

          send(parent, {:lock_held, self()})

          receive do
            :release -> :ok
          after
            @lock_wait_timeout_ms -> :ok
          end
        end)
      end)

    receive do
      {:lock_held, ^pid} -> pid
    after
      @lock_wait_timeout_ms -> raise "the workflow lock holder never took the lock"
    end
  end

  defp release_lock_holder(pid) do
    reference = Process.monitor(pid)
    send(pid, :release)

    receive do
      {:DOWN, ^reference, :process, ^pid, _reason} -> :ok
    after
      @lock_wait_timeout_ms -> raise "the lock holder never released the organization row lock"
    end
  end

  defp await_all_blocked_on_lock(backend_pids) do
    await_all_blocked_on_lock(
      backend_pids,
      System.monotonic_time(:millisecond) + @lock_wait_timeout_ms
    )
  end

  defp await_all_blocked_on_lock(backend_pids, deadline) do
    wanted = length(backend_pids)
    blocked = blocked_count(backend_pids)

    cond do
      blocked == wanted ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        raise "only #{blocked} of #{wanted} racers parked on the organization row lock"

      true ->
        Process.sleep(10)
        await_all_blocked_on_lock(backend_pids, deadline)
    end
  end

  defp blocked_count(backend_pids) do
    %{rows: [[count]]} =
      Alplus.Repo.query!(
        """
        SELECT count(*)
        FROM pg_stat_activity
        WHERE pid = ANY($1::int[]) AND wait_event_type = 'Lock'
        """,
        [backend_pids]
      )

    count
  end

  defp await_ready do
    receive do
      {:racer_ready, backend_pid} -> backend_pid
    after
      @lock_wait_timeout_ms -> raise "a racing process never checked out its connection"
    end
  end
end
