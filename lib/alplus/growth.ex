defmodule Alplus.Growth do
  @moduledoc """
  Organic acquisition: where an account came from, and which content
  cluster earned it.

  This domain exists so growth reporting can answer the only question that
  matters about content, which is whether it produced activated
  organizations, rather than whether it ranked. Rankings are a leading
  indicator we do not control; activation is an outcome we do.

  Two things live here:

  * `record_signup_attribution/2`, called once at registration.
  * `targets/0`, the one configurable source of growth targets, so a number
    like "5% organic signup conversion" is never hard-coded across the app.

  Reads are staff reporting only and require `authorize?: false`; nothing in
  the console surfaces them yet.
  """

  use Ash.Domain, otp_app: :alplus

  resources do
    resource Alplus.Growth.SignupAttribution do
      define :record_signup_attribution_row, action: :record
      define :list_signup_attributions, action: :read
    end

    resource Alplus.Growth.JourneyEvent do
      define :record_journey_event, action: :record
      define :list_journey_events, action: :read
    end

    resource Alplus.Growth.DailyCount do
      define :list_health_check_daily_counts, action: :read
    end
  end

  @doc """
  Records how a user arrived, from the attribution map
  `AlplusWeb.Plugs.AcquisitionAttribution` left in the session.

  Returns `:ok` in every case, including failure. Acquisition reporting is
  never allowed to break a registration: a signup that succeeds but goes
  unattributed costs a row in a report, while a signup that fails because
  reporting failed costs a customer.
  """
  @spec record_signup_attribution(String.t(), map() | nil) :: :ok
  # No attribution in the session means the visitor never passed through a
  # public marketing page: they arrived at /register directly, or from a
  # link that skipped the site. Recorded as "direct" rather than skipped, so
  # every signup appears in acquisition reporting and the organic share is a
  # real proportion instead of a count over an unknown denominator.
  def record_signup_attribution(user_id, nil) do
    write(%{
      user_id: user_id,
      landing_page: "/register",
      referrer_host: nil,
      utm: %{},
      content_cluster: "direct",
      first_seen_at: nil
    })
  end

  def record_signup_attribution(user_id, %{} = attribution) do
    landing_page = Map.get(attribution, "landing_page") || "/"

    write(%{
      user_id: user_id,
      landing_page: landing_page,
      referrer_host: Map.get(attribution, "referrer_host"),
      utm: Map.get(attribution, "utm") || %{},
      content_cluster: content_cluster(landing_page),
      first_seen_at: parse_timestamp(Map.get(attribution, "first_seen_at"))
    })
  end

  def record_signup_attribution(user_id, _other), do: record_signup_attribution(user_id, nil)

  defp write(attrs) do
    case record_signup_attribution_row(attrs, authorize?: false) do
      {:ok, _row} ->
        :ok

      {:error, error} ->
        require Logger

        Logger.warning("signup attribution not recorded: #{inspect(error)}")
        :ok
    end
  end

  @doc """
  The content cluster a landing path belongs to.

  Clusters are the reporting unit for content: they turn a set of URLs into
  a line like "cron content produced 31 signups". Resolved from the path at
  write time, so later URL changes cannot rewrite history.
  """
  @spec content_cluster(String.t()) :: String.t()
  def content_cluster("/monitoring/cron-jobs"), do: "cron"
  def content_cluster("/free-cron-job-monitoring"), do: "cron"
  def content_cluster("/guides/github-actions-heartbeat"), do: "cron"
  def content_cluster("/guides/kubernetes-cronjob-heartbeat"), do: "cron"
  def content_cluster("/guides/heroku-scheduler-heartbeat"), do: "cron"
  def content_cluster("/guides/systemd-timer-heartbeat"), do: "cron"
  def content_cluster("/guides/laravel-scheduler-heartbeat"), do: "cron"
  def content_cluster("/guides/airflow-heartbeat"), do: "cron"
  def content_cluster("/guides/gitlab-ci-schedule-heartbeat"), do: "cron"
  def content_cluster("/guides/backup-heartbeat"), do: "cron"
  def content_cluster("/guides/why-analytics-tools-disagree"), do: "measure"
  def content_cluster("/guides/investigate-errors-after-release"), do: "observe"
  def content_cluster("/guides/ssl-certificate-expiry"), do: "uptime"
  def content_cluster("/monitoring/uptime"), do: "uptime"
  def content_cluster("/free-uptime-monitoring"), do: "uptime"
  def content_cluster("/tools/website-health-check"), do: "uptime"
  def content_cluster("/monitoring/api"), do: "api"
  def content_cluster("/monitoring"), do: "monitoring"
  def content_cluster("/error-tracking"), do: "observe"
  def content_cluster("/analytics"), do: "measure"
  def content_cluster("/privacy"), do: "trust"
  def content_cluster("/about"), do: "trust"
  def content_cluster("/terms"), do: "trust"
  def content_cluster("/pricing"), do: "pricing"
  def content_cluster("/guides"), do: "guides"
  def content_cluster("/changelog"), do: "changelog"
  def content_cluster("/blog"), do: "observability"

  def content_cluster("/blog/" <> slug) do
    case Alplus.Content.get_article_by_slug(slug) do
      {:ok, article} -> article.cluster
      {:error, _} -> "other"
    end
  end

  def content_cluster("/"), do: "home"

  def content_cluster("/docs"), do: "docs"
  def content_cluster("/docs/" <> _), do: "docs"
  def content_cluster("/alternatives" <> _), do: "comparison"
  def content_cluster("/guides/" <> _), do: "guides"
  def content_cluster("/monitoring/" <> _), do: "monitoring"
  def content_cluster(_), do: "other"

  @doc "Provisional 90-day growth targets, in one place."
  @spec targets() :: map()
  def targets do
    %{
      non_branded_organic_impressions: 25_000,
      organic_visits: 2_000,
      organic_signup_conversion_rate: 0.05,
      signup_to_activation_rate: 0.35,
      activation_to_paid_rate: 0.10,
      new_referring_domains: 20,
      ai_query_mention_rate: 0.20,
      high_intent_pages_indexed_rate: 0.95
    }
  end

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> timestamp
      _ -> nil
    end
  end

  defp parse_timestamp(_), do: nil
end
