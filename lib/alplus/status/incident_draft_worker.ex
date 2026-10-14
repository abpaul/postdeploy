defmodule Alplus.Status.IncidentDraftWorker do
  @moduledoc "Delivers one private Status draft from one persisted Monitor incident workflow."

  use Oban.Worker, queue: :telemetry, max_attempts: 3

  alias Alplus.Repo
  alias Alplus.Status

  require Logger

  @max_attempts 3
  @max_failure_reason_bytes 2048

  @doc "Persists a reconciliation signal inside the Monitor incident transaction."
  def persist_reconciliation_signal!(monitor, incident_id) when is_binary(incident_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.query!(
      """
      INSERT INTO monitor_incident_status_draft_reconciliations
        (id, org_id, project_id, monitor_id, incident_id, state, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, 'pending', $6, $6)
      ON CONFLICT (incident_id) DO NOTHING
      """,
      [
        Alplus.Id.generate(:status_incident_draft),
        monitor.org_id,
        monitor.project_id,
        monitor.id,
        incident_id,
        now
      ]
    )

    :ok
  end

  @doc "Reconciles one committed incident into durable Status draft workflows."
  def reconcile_for_incident(org_id, project_id, incident_id)
      when is_binary(org_id) and is_binary(project_id) and is_binary(incident_id) do
    try do
      with {:ok, monitor_id} <-
             Status.Queries.monitor_id_for_incident(org_id, project_id, incident_id) do
        case reconcile(org_id, project_id, monitor_id, incident_id) do
          {:ok, _jobs} = result ->
            complete_signal_if_terminal(org_id, project_id, monitor_id, incident_id)
            result

          error ->
            error
        end
      end
    rescue
      error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, error}
    end
  end

  def reconcile_for_incident(_org_id, _project_id, _incident_id), do: {:error, :invalid_args}

  @doc "Reconciles only incident signals persisted by this workflow."
  def reconcile_pending do
    Repo.query!(
      "SELECT org_id, project_id, incident_id FROM monitor_incident_status_draft_reconciliations WHERE state = 'pending' ORDER BY inserted_at"
    ).rows
    |> Enum.each(fn [org_id, project_id, incident_id] ->
      case reconcile_for_incident(org_id, project_id, incident_id) do
        {:ok, _jobs} ->
          :ok

        {:error, reason} ->
          Logger.error("incident draft reconciliation failed: #{inspect(reason)}")
      end
    end)

    :ok
  end

  # Kept for callers that already hold a Monitor. This still derives all
  # workflow targets from tenant-scoped persisted rows.
  def enqueue_for_monitor(monitor, incident_id) when is_binary(incident_id) do
    reconcile(monitor.org_id, monitor.project_id, monitor.id, incident_id)
  end

  defp reconcile(org_id, project_id, monitor_id, incident_id) do
    org_id
    |> Status.Queries.pages_with_monitor(project_id, monitor_id)
    |> Enum.reduce_while({:ok, []}, fn status_page_id, {:ok, jobs} ->
      identity = identity(org_id, project_id, monitor_id, incident_id, status_page_id)

      case ensure_workflow(identity) do
        {:ok, nil} ->
          {:cont, {:ok, jobs}}

        {:ok, workflow} ->
          case enqueue_pending(workflow, identity) do
            {:ok, job} -> {:cont, {:ok, [job | jobs]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, jobs} -> {:ok, Enum.reverse(jobs)}
      error -> error
    end)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    try do
      with {:ok, identity} <- validate_args(job.args),
           {:ok, workflow} <- reserve_attempt(identity, job.attempt),
           result <- perform_transaction(identity, workflow) do
        result
      else
        {:error, :invalid_args} -> {:cancel, "invalid_incident_draft_job"}
      end
    rescue
      error in Postgrex.Error ->
        handle_database_failure(job, error.postgres.code)

      error in DBConnection.ConnectionError ->
        handle_database_failure(job, connection_failure_reason(error))
    end
  end

  defp perform_transaction(identity, _workflow) do
    case Repo.transaction(fn ->
           with {:ok, workflow} <- lock_workflow(identity) do
             deliver(workflow, identity)
           else
             {:error, :workflow_not_found} -> {:cancel, "incident_draft_workflow_not_found"}
             {:error, reason} -> Repo.rollback({:retry, {:incident_draft_lookup_failed, reason}})
           end
         end) do
      {:ok, {:delivered, project_id}} ->
        Phoenix.PubSub.broadcast(
          Alplus.PubSub,
          "monitor:#{project_id}",
          {:monitor_updated, project_id}
        )

        :ok

      {:ok, result} ->
        result

      {:error, {:retry, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:incident_draft_transaction_failed, reason}}
    end
  end

  defp deliver(%{state: "delivered"}, _identity), do: :ok
  defp deliver(%{state: "failed", failure_reason: reason}, _identity), do: {:cancel, reason}

  defp deliver(workflow, identity) do
    cond do
      not incident_exists?(identity) ->
        cancel(workflow.id, "incident_not_found_for_monitor_scope")

      not page_exposes_monitor?(identity) ->
        cancel(workflow.id, "status_page_not_linked_to_monitor_scope")

      true ->
        create_draft(workflow, identity)
    end
  end

  defp create_draft(workflow, identity) do
    case Status.create_failure_draft(
           identity.org_id,
           identity.project_id,
           identity.status_page_id,
           identity.monitor_id,
           identity.incident_id
         ) do
      {:ok, _draft} ->
        mark_delivered(workflow.id)
        {:delivered, identity.project_id}

      {:error, {:permanent, reason}} ->
        cancel(workflow.id, reason)

      {:error, reason} ->
        cancel(workflow.id, "incident_draft_permanent_failure:#{inspect(reason)}")
    end
  end

  defp handle_database_failure(job, code) do
    with {:ok, identity} <- validate_args(job.args) do
      persist_transient_cause(identity, code)

      case Repo.transaction(fn ->
             with {:ok, workflow} <- lock_workflow(identity) do
               case database_result(code) do
                 {:retry, reason} when workflow.attempt_count >= @max_attempts ->
                   cancel(
                     workflow.id,
                     "retry_exhausted_after_#{@max_attempts}_attempts:#{reason}"
                   )

                 {:retry, reason} ->
                   Repo.rollback({:retry, reason})

                 {:permanent, reason} ->
                   cancel(workflow.id, reason)
               end
             else
               {:error, :workflow_not_found} -> database_failure_without_workflow(job, code)
               {:error, reason} -> Repo.rollback({:retry, reason})
             end
           end) do
        {:ok, result} -> result
        {:error, {:retry, reason}} -> {:error, reason}
        {:error, reason} -> {:error, {:incident_draft_failure_record_failed, reason}}
      end
    else
      {:error, :invalid_args} -> {:cancel, "invalid_incident_draft_job"}
    end
  end

  defp database_result(code)
       when code in [
              "40001",
              "40P01",
              "08000",
              "08001",
              "08003",
              "08006",
              "57P01",
              "57P02",
              "57P03",
              "serialization_failure",
              "deadlock_detected",
              "connection_exception",
              "connection_failure",
              "connection_error",
              "connection_does_not_exist",
              "admin_shutdown",
              "crash_shutdown",
              "cannot_connect_now",
              "connection_failure",
              :serialization_failure,
              :deadlock_detected,
              :connection_exception,
              :connection_failure,
              :connection_error,
              :connection_does_not_exist,
              :admin_shutdown,
              :crash_shutdown,
              :cannot_connect_now
            ],
       do: {:retry, "database_transient_#{code}"}

  defp database_result(code), do: {:permanent, "database_permanent_#{code}"}

  # A rejected transaction can discard the worker connection before the
  # failure handler reacquires it. Preserve the job's classified outcome;
  # reconciliation finds the persisted ledger after the connection recovers.
  defp database_failure_without_workflow(job, code) do
    case database_result(code) do
      {:retry, reason} when job.attempt >= job.max_attempts ->
        {:cancel, "retry_exhausted_after_#{@max_attempts}_attempts:#{reason}"}

      {:retry, reason} ->
        Repo.rollback({:retry, reason})

      {:permanent, reason} ->
        {:cancel, reason}
    end
  end

  defp connection_failure_reason(%DBConnection.ConnectionError{message: message})
       when is_binary(message),
       do: "connection_error"

  defp connection_failure_reason(_error), do: "connection_error"

  defp ensure_workflow(identity) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.query!(
      """
      INSERT INTO monitor_incident_status_draft_workflows
        (id, org_id, project_id, monitor_id, incident_id, status_page_id, state, attempt_count, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, 'pending', 0, $7, $7)
      ON CONFLICT (org_id, project_id, monitor_id, incident_id, status_page_id) DO NOTHING
      """,
      [
        Alplus.Id.generate(:status_incident_draft),
        identity.org_id,
        identity.project_id,
        identity.monitor_id,
        identity.incident_id,
        identity.status_page_id,
        now
      ]
    )

    case Repo.query(
           "SELECT id, state, attempt_count FROM monitor_incident_status_draft_workflows WHERE org_id = $1 AND project_id = $2 AND monitor_id = $3 AND incident_id = $4 AND status_page_id = $5",
           identity_values(identity)
         ) do
      {:ok, %{rows: [[id, "pending", attempts]]}} when attempts < @max_attempts ->
        {:ok, %{id: id, state: "pending"}}

      {:ok, %{rows: [[id, "pending", _attempts]]}} ->
        update_workflow(id, "failed", retry_exhausted_reason(%{failure_reason: nil}))
        {:ok, nil}

      {:ok, %{rows: [[_id, _state, _attempts]]}} ->
        {:ok, nil}

      {:ok, %{rows: []}} ->
        {:error, :workflow_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enqueue_pending(%{id: workflow_id}, identity) do
    args = identity |> string_identity() |> Map.put("workflow_id", workflow_id)

    new(args, unique: [period: :infinity, keys: [:workflow_id], states: :incomplete])
    |> Oban.insert()
  end

  defp lock_workflow(identity) do
    case Repo.query(
           "SELECT id, state, failure_reason, attempt_count FROM monitor_incident_status_draft_workflows WHERE id = $1 AND org_id = $2 AND project_id = $3 AND monitor_id = $4 AND incident_id = $5 AND status_page_id = $6 FOR UPDATE",
           [identity.workflow_id | identity_values(identity)]
         ) do
      {:ok, %{rows: [[id, state, failure_reason, attempt_count]]}} ->
        {:ok,
         %{id: id, state: state, failure_reason: failure_reason, attempt_count: attempt_count}}

      {:ok, %{rows: []}} ->
        {:error, :workflow_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reserve_attempt(identity, oban_attempt) do
    Repo.transaction(fn ->
      with {:ok, workflow} <- lock_workflow(identity) do
        attempt_count = max(workflow.attempt_count + 1, oban_attempt)

        if workflow.state == "pending" and attempt_count <= @max_attempts do
          Repo.query!(
            "UPDATE monitor_incident_status_draft_workflows SET attempt_count = $2, updated_at = $3 WHERE id = $1",
            [workflow.id, attempt_count, DateTime.utc_now() |> DateTime.truncate(:microsecond)]
          )

          {:ok, %{workflow | attempt_count: attempt_count}}
        else
          if workflow.state == "pending" do
            update_workflow(
              workflow.id,
              "failed",
              retry_exhausted_reason(workflow)
            )

            {:ok,
             %{
               workflow
               | state: "failed",
                 failure_reason: retry_exhausted_reason(workflow)
             }}
          else
            {:ok, workflow}
          end
        end
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp complete_signal_if_terminal(org_id, project_id, monitor_id, incident_id) do
    Repo.query!(
      """
      UPDATE monitor_incident_status_draft_reconciliations AS signal
      SET state = 'reconciled', updated_at = $5
      WHERE signal.org_id = $1 AND signal.project_id = $2 AND signal.monitor_id = $3
        AND signal.incident_id = $4 AND signal.state = 'pending'
        AND NOT EXISTS (
          SELECT 1
          FROM monitor_incident_status_draft_workflows AS workflow
          WHERE workflow.org_id = signal.org_id AND workflow.project_id = signal.project_id
            AND workflow.monitor_id = signal.monitor_id AND workflow.incident_id = signal.incident_id
            AND workflow.state = 'pending'
        )
      """,
      [
        org_id,
        project_id,
        monitor_id,
        incident_id,
        DateTime.utc_now() |> DateTime.truncate(:microsecond)
      ]
    )
  end

  defp mark_delivered(id), do: update_workflow(id, "delivered", nil)

  defp cancel(id, reason) do
    update_workflow(id, "failed", reason)
    {:cancel, reason}
  end

  defp update_workflow(id, state, reason) do
    Repo.query!(
      "UPDATE monitor_incident_status_draft_workflows SET state = $2, failure_reason = $3, updated_at = $4 WHERE id = $1 AND state = 'pending'",
      [id, state, truncate_reason(reason), DateTime.utc_now() |> DateTime.truncate(:microsecond)]
    )
  end

  defp persist_transient_cause(identity, code) do
    case database_result(code) do
      {:retry, reason} ->
        Repo.query!(
          "UPDATE monitor_incident_status_draft_workflows SET failure_reason = $2, updated_at = $3 WHERE id = $1 AND org_id = $4 AND project_id = $5 AND monitor_id = $6 AND incident_id = $7 AND status_page_id = $8 AND state = 'pending'",
          [
            identity.workflow_id,
            truncate_reason(reason),
            DateTime.utc_now() |> DateTime.truncate(:microsecond),
            identity.org_id,
            identity.project_id,
            identity.monitor_id,
            identity.incident_id,
            identity.status_page_id
          ]
        )

      {:permanent, _reason} ->
        :ok
    end
  end

  defp retry_exhausted_reason(%{failure_reason: reason}) do
    "retry_exhausted_after_#{@max_attempts}_attempts:" <> (reason || "transient_failure")
  end

  defp truncate_reason(nil), do: nil

  defp truncate_reason(reason) do
    reason = to_string(reason)

    if byte_size(reason) <= @max_failure_reason_bytes do
      reason
    else
      reason
      |> binary_part(0, @max_failure_reason_bytes)
      |> trim_invalid_utf8()
    end
  end

  defp trim_invalid_utf8(value) when is_binary(value) do
    if String.valid?(value) do
      value
    else
      value
      |> byte_size()
      |> Kernel.-(1)
      |> then(&binary_part(value, 0, &1))
      |> trim_invalid_utf8()
    end
  end

  defp validate_args(%{
         "workflow_id" => workflow_id,
         "org_id" => org_id,
         "project_id" => project_id,
         "monitor_id" => monitor_id,
         "incident_id" => incident_id,
         "status_page_id" => status_page_id
       })
       when is_binary(workflow_id) and is_binary(org_id) and is_binary(project_id) and
              is_binary(monitor_id) and is_binary(incident_id) and is_binary(status_page_id),
       do:
         {:ok,
          %{
            workflow_id: workflow_id,
            org_id: org_id,
            project_id: project_id,
            monitor_id: monitor_id,
            incident_id: incident_id,
            status_page_id: status_page_id
          }}

  defp validate_args(_args), do: {:error, :invalid_args}

  defp incident_exists?(value),
    do:
      Status.Queries.monitor_incident_exists?(
        value.org_id,
        value.project_id,
        value.monitor_id,
        value.incident_id
      )

  defp page_exposes_monitor?(value),
    do:
      value.status_page_id in Status.Queries.pages_with_monitor(
        value.org_id,
        value.project_id,
        value.monitor_id
      )

  defp identity(org_id, project_id, monitor_id, incident_id, status_page_id),
    do: %{
      org_id: org_id,
      project_id: project_id,
      monitor_id: monitor_id,
      incident_id: incident_id,
      status_page_id: status_page_id
    }

  defp identity_values(value),
    do: [
      value.org_id,
      value.project_id,
      value.monitor_id,
      value.incident_id,
      value.status_page_id
    ]

  defp string_identity(value),
    do: %{
      "org_id" => value.org_id,
      "project_id" => value.project_id,
      "monitor_id" => value.monitor_id,
      "incident_id" => value.incident_id,
      "status_page_id" => value.status_page_id
    }
end
