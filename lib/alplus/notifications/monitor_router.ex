defmodule Alplus.Notifications.MonitorRouter do
  @moduledoc false

  # Called inside the same database transaction that changes an incident. Oban
  # rows commit or roll back with that state; the delivery ledger supplies the
  # final external-effect deduplication.
  alias Alplus.Notifications.DeliveryWorker

  @spec enqueue!(map(), String.t(), String.t(), non_neg_integer()) :: :ok
  def enqueue!(monitor, trigger, incident_id, repeat_index)
      when trigger in ["check_down", "check_recovered"] do
    %{rows: rules} =
      Alplus.Repo.query!(
        """
        SELECT r.id, c.id, c.type
        FROM alert_rules AS r
        INNER JOIN notification_channels AS c ON c.id = r.channel_id
        WHERE r.org_id = $1 AND r.project_id = $2 AND r.module = 'monitor'
          AND r.trigger_type = $3 AND r.enabled = true
        """,
        [monitor.org_id, monitor.project_id, trigger]
      )

    Enum.each(rules, fn [rule_id, channel_id, channel_type] ->
      {:ok, _access} = Alplus.Billing.Access.check(monitor.org_id)

      {:ok, _job} =
        DeliveryWorker.new(%{
          "org_id" => monitor.org_id,
          "alert_rule_id" => rule_id,
          "channel_id" => channel_id,
          "channel_type" => channel_type,
          "trigger" => trigger,
          "subject_type" => "incident",
          "subject_id" => incident_id,
          "repeat_index" => Integer.to_string(repeat_index)
        })
        |> Oban.insert()
    end)

    :ok
  end
end
