defmodule Alplus.Monitoring.ExpiryScanWorker do
  @moduledoc """
  Durable daily maintenance entry point for expiry scans.

  The worker returns warning records to its caller. A routing layer consumes
  those records and writes the idempotency key before it enqueues notifications.
  Keeping the scan separate prevents an outbound adapter failure from causing a
  fresh network scan on every delivery retry.
  """

  use Oban.Worker, queue: :telemetry, max_attempts: 3

  alias Alplus.Monitoring.ExpiryScan
  alias Alplus.Notifications.DeliveryWorker

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    %{failures: failures, warnings: warnings} = result = ExpiryScan.scan_active()

    route(warnings)

    if failures == [] do
      {:ok, result}
    else
      {:error, {:expiry_scans_failed, length(failures)}}
    end
  end

  @doc "Enqueues one notification per enabled alert rule for each warning."
  @spec route([Alplus.Monitoring.ExpiryScan.warning()]) :: :ok
  def route(warnings), do: Enum.each(warnings, &route_warning!/1)

  defp route_warning!(warning) do
    %{rows: rules} =
      Alplus.Repo.query!(
        """
        SELECT r.id, c.id, c.type
        FROM alert_rules AS r
        INNER JOIN notification_channels AS c ON c.id = r.channel_id
        WHERE r.org_id = $1 AND r.project_id = $2 AND r.module = 'monitor'
          AND r.trigger_type = $3 AND r.enabled = true
        """,
        [warning.org_id, warning.project_id, Atom.to_string(warning.kind)]
      )

    Enum.each(rules, fn [rule_id, channel_id, channel_type] ->
      # An inactive organization gets no enqueued warning: delivery re-resolves
      # access anyway (issue #61 item 9), so the job would be refused.
      with {:ok, _access} <- Alplus.Billing.Access.check(warning.org_id) do
        {:ok, _job} =
          DeliveryWorker.enqueue(%{
            "org_id" => warning.org_id,
            "alert_rule_id" => rule_id,
            "channel_id" => channel_id,
            "channel_type" => channel_type,
            "trigger" => Atom.to_string(warning.kind),
            "subject_type" => "monitor",
            "subject_id" => warning.monitor_id,
            "repeat_index" => Integer.to_string(warning.threshold_days),
            "occurrence" => DateTime.to_iso8601(warning.expires_at)
          })
      end
    end)
  end
end
