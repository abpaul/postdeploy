defmodule Alplus.Status.RecoveryWorker do
  @moduledoc "Publishes one recovery update when a linked Monitor incident resolves."

  use Oban.Worker, queue: :telemetry, max_attempts: 3

  alias Alplus.Repo
  alias Alplus.Status.StatusIncident

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: run()

  @doc "Runs the idempotent recovery scan once."
  def run do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Repo.transaction(fn ->
           # Lock candidate status incidents so concurrent Oban runs publish once.
           Repo.query!("""
           SELECT si.id, si.org_id, si.project_id, i.resolved_at
           FROM status_incidents AS si
           INNER JOIN incidents AS i ON i.id = si.incident_id
           WHERE si.status = 'open' AND i.status = 'resolved' AND si.recovery_posted_at IS NULL
             AND i.org_id = si.org_id AND i.project_id = si.project_id
           FOR UPDATE OF si
           """).rows
           |> Enum.reduce([], fn [incident_id, org_id, project_id, resolved_at], notifications ->
             body = "Service recovered at #{format_time(resolved_at || now)} UTC."

             case Ash.get(StatusIncident, incident_id, authorize?: false) do
               {:ok, status_incident} ->
                 with {:ok, _update, update_notifications} <-
                        Ash.create(
                          Alplus.Status.StatusIncidentUpdate,
                          %{
                            org_id: org_id,
                            project_id: project_id,
                            status_incident_id: incident_id,
                            body: body
                          },
                          action: :recovery,
                          authorize?: false,
                          return_notifications?: true,
                          context: %{warn_on_transaction_hooks?: false}
                        ),
                      {:ok, _status_incident, marker_notifications} <-
                        Ash.update(status_incident, %{},
                          action: :auto_recovery,
                          authorize?: false,
                          return_notifications?: true,
                          context: %{warn_on_transaction_hooks?: false}
                        ) do
                   update_notifications ++ marker_notifications ++ notifications
                 else
                   {:error, error} ->
                     Repo.rollback({:recovery_update_failed, error})
                 end

               {:error, error} ->
                 Repo.rollback({:recovery_incident_missing, error})
             end
           end)
         end) do
      {:ok, notifications} ->
        Alplus.Measure.PublicCache.clear()
        Ash.Notifier.notify(notifications)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_time(%DateTime{} = value), do: Calendar.strftime(value, "%H:%M")

  defp format_time(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> format_time()
end
