defmodule Alplus.Observe.AlertRouter do
  @moduledoc false

  alias Alplus.Notifications.DeliveryWorker
  alias Alplus.Repo

  @cooldown_seconds 15 * 60

  @spec fanout_issue(map(), String.t()) :: :ok
  def fanout_issue(issue, trigger)
      when trigger in ["new_issue", "issue_regression", "error_spike"] do
    rules(issue.org_id, issue.project_id, trigger)
    |> Enum.each(fn rule ->
      if frequency_allowed?(rule.condition, issue.id, trigger) and
           cooldown?(rule.id, "issue", issue.id, trigger) do
        enqueue(rule, issue.org_id, "issue", issue.id, trigger)
      end
    end)

    :ok
  end

  @spec fanout_quota(String.t(), String.t()) :: :ok
  def fanout_quota(org_id, project_id) do
    rules(org_id, project_id, "quota")
    |> Enum.each(fn rule ->
      if cooldown?(rule.id, "project", project_id, "quota") do
        enqueue(rule, org_id, "project", project_id, "quota")
      end
    end)

    :ok
  end

  defp rules(org_id, project_id, trigger) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT r.id, r.condition, c.id, c.type FROM alert_rules r
        JOIN notification_channels c ON c.id = r.channel_id
        WHERE r.org_id = $1 AND r.project_id = $2 AND r.module = 'observe'
          AND r.trigger_type = $3 AND r.enabled = true
        """,
        [org_id, project_id, trigger]
      )

    Enum.map(rows, fn [id, condition, channel_id, channel_type] ->
      %{id: id, condition: condition, channel_id: channel_id, channel_type: channel_type}
    end)
  end

  defp frequency_allowed?(condition, issue_id, "error_spike") do
    case Map.get(condition || %{}, "threshold", 25) do
      threshold when is_integer(threshold) and threshold > 0 ->
        %{rows: [[count]]} =
          Repo.query!(
            "SELECT count(*) FROM error_events WHERE issue_id = $1 AND received_at >= now() - interval '5 minutes'",
            [issue_id]
          )

        count >= threshold

      _ ->
        false
    end
  end

  defp frequency_allowed?(_condition, _issue_id, _trigger), do: true

  defp cooldown?(rule_id, subject_type, subject_id, trigger) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    cutoff = DateTime.add(now, -@cooldown_seconds, :second)

    %{rows: rows} =
      Repo.query!(
        """
        INSERT INTO observe_alert_cooldowns (alert_rule_id, subject_type, subject_id, trigger, last_notified_at)
        VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (alert_rule_id, subject_type, subject_id, trigger) DO UPDATE
        SET last_notified_at = EXCLUDED.last_notified_at
        WHERE observe_alert_cooldowns.last_notified_at <= $6
        RETURNING alert_rule_id
        """,
        [rule_id, subject_type, subject_id, trigger, now, cutoff]
      )

    rows != []
  end

  defp enqueue(rule, org_id, subject_type, subject_id, trigger) do
    with :ok <- Alplus.Notifications.AlertRateLimiter.check(org_id),
         :ok <- Alplus.Ingest.OperationalMonitor.reserve_notification() do
      insert_notification(rule, org_id, subject_type, subject_id, trigger)
    else
      {:error, reason} when reason in [:tenant_limit, :global_limit, :backlog_full] ->
        suppressed(reason)
    end
  end

  defp insert_notification(rule, org_id, subject_type, subject_id, trigger) do
    with {:ok, _access} <- Alplus.Billing.Access.check(org_id),
         {:ok, _job} <-
           DeliveryWorker.new(%{
             "org_id" => org_id,
             "alert_rule_id" => rule.id,
             "channel_id" => rule.channel_id,
             "channel_type" => rule.channel_type,
             "trigger" => trigger,
             "subject_type" => subject_type,
             "subject_id" => subject_id,
             "repeat_index" => "0"
           })
           |> Oban.insert() do
      :ok
    else
      {:error, _reason} ->
        Alplus.Ingest.OperationalMonitor.release_notification()
        suppressed(:queue_unavailable)
    end
  end

  defp suppressed(reason) do
    :telemetry.execute(
      [:alplus, :ingest, :notification, :suppressed],
      %{count: 1},
      %{reason: reason}
    )

    :ok
  end
end
