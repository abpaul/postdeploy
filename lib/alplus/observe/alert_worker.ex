defmodule Alplus.Observe.AlertWorker do
  @moduledoc """
  Fans out Observe alerts after an event has committed.

  Jobs carry the event's persisted composite key rather than an event struct.
  A missing event means retention already removed the work and is a successful
  no-op. AlertRouter and notification delivery provide their own cooldown and
  delivery-key idempotency, so retrying this worker cannot duplicate sends.
  """

  use Oban.Worker,
    queue: :notify,
    max_attempts: 10,
    unique: [
      period: {7, :days},
      keys: [:event_id, :received_at],
      states: :incomplete
    ]

  alias Alplus.Observe.AlertRouter
  alias Alplus.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "event_id" => event_id,
          "received_at" => received_at,
          "new_issue" => new_issue,
          "regression" => regression
        }
      })
      when is_binary(event_id) and is_binary(received_at) and is_boolean(new_issue) and
             is_boolean(regression) do
    with {:ok, received_at} <- parse_received_at(received_at),
         {:ok, event} <- find_event(event_id, received_at),
         issue = %{id: event.issue_id, org_id: event.org_id, project_id: event.project_id},
         :ok <- maybe_fanout(new_issue, issue, "new_issue"),
         :ok <- maybe_fanout(regression, issue, "issue_regression"),
         :ok <- AlertRouter.fanout_issue(issue, "error_spike") do
      :ok
    else
      :not_found -> :ok
      {:error, :invalid_received_at} -> {:cancel, :invalid_alert_job}
      {:error, reason} -> {:error, {:alert_dispatch_failed, reason}}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_alert_job}

  defp parse_received_at(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :invalid_received_at}
    end
  end

  defp maybe_fanout(false, _issue, _trigger), do: :ok
  defp maybe_fanout(true, issue, trigger), do: AlertRouter.fanout_issue(issue, trigger)

  defp find_event(event_id, received_at) do
    case Repo.query(
           """
           SELECT issue_id, org_id, project_id
           FROM error_events
           WHERE event_id = $1 AND received_at = $2
           """,
           [event_id, received_at]
         ) do
      {:ok, %{rows: [[issue_id, org_id, project_id]]}} ->
        {:ok, %{issue_id: issue_id, org_id: org_id, project_id: project_id}}

      {:ok, %{rows: []}} ->
        :not_found

      {:error, reason} ->
        {:error, reason}
    end
  end
end
