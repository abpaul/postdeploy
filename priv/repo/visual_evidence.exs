# Gives the visual-review workspace real monitor evidence: an HTTP config with
# a check interval, plus a window of recorded checks, so the availability strip
# and the response-time chart draw from data rather than from the
# "interval unavailable" error state. Development only.
defmodule Alplus.VisualEvidence do
  @moduledoc false

  require Ash.Query

  alias Alplus.Monitoring.{HttpConfig, MonitorCheck}
  alias Alplus.{Monitoring, Orgs, Projects, Scope}
  alias Alplus.Accounts.User

  @email "visual-review@example.com"
  @checks 96

  def run do
    unless Mix.env() == :dev, do: raise("visual_evidence.exs is a development-only script")

    user =
      User
      |> Ash.Query.filter(email == ^@email)
      |> Ash.read_one!(authorize?: false)

    user_scope = Scope.for_user(user.id)
    [org | _] = Orgs.list_organizations!(actor: user_scope)
    {:ok, org_scope} = Orgs.build_scope(user_scope, org.id)
    [project | _] = Projects.list_projects_for_org!(org.id, actor: org_scope)
    scope = Scope.put_project(org_scope, project.id)

    for monitor <- Monitoring.list_monitors_for_project!(project.id, actor: scope),
        monitor.type in ["http", "keyword"] do
      ensure_config(scope, org, monitor)
      record_checks(org, project, monitor)
      IO.puts("evidence for #{monitor.name}")
    end
  end

  defp ensure_config(scope, org, monitor) do
    HttpConfig
    |> Ash.Query.filter(monitor_id == ^monitor.id)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil ->
        Ash.create!(
          HttpConfig,
          %{
            monitor_id: monitor.id,
            org_id: org.id,
            url: "https://#{monitor.name}/health",
            method: "GET",
            expected_status: %{"kind" => "range", "min" => 200, "max" => 399},
            interval_seconds: 900,
            timeout_seconds: 10,
            response_time_threshold_ms: 400
          },
          action: :create,
          actor: scope
        )

      config ->
        config
    end
  end

  defp record_checks(org, project, monitor) do
    now = DateTime.utc_now()

    for index <- 0..(@checks - 1) do
      checked_at = DateTime.add(now, -index * 900, :second)
      slow? = rem(index, 11) == 0
      down? = rem(index, 29) == 0

      Ash.create!(
        MonitorCheck,
        %{
          org_id: org.id,
          project_id: project.id,
          monitor_id: monitor.id,
          environment: monitor.environment || "production",
          status: if(down?, do: "down", else: "up"),
          checked_at: checked_at,
          status_code: if(down?, do: 503, else: 200),
          latency_ms: if(slow?, do: 640, else: 120 + rem(index * 17, 90))
        },
        action: :record,
        authorize?: false
      )
    end
  end
end

Alplus.VisualEvidence.run()
