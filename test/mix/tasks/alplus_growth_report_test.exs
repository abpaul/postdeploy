defmodule Mix.Tasks.Alplus.Growth.ReportTest do
  @moduledoc """
  The growth report renders real funnel numbers.

  A report is only useful if it is right, so this builds an activated
  account and a stalled one, then asserts both appear with the correct
  counts and rate. Running the task against an empty database would prove
  only that it does not crash.
  """

  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures
  import ExUnit.CaptureIO

  alias Alplus.Growth
  alias Alplus.Monitoring.Monitor
  alias Alplus.Scope

  defp run_report(args \\ []) do
    capture_io(fn -> Mix.Tasks.Alplus.Growth.Report.run(args) end)
  end

  defp signed_up(landing_page) do
    user = user_fixture()

    :ok =
      Growth.record_signup_attribution(user.id, %{
        "landing_page" => landing_page,
        "referrer_host" => nil,
        "utm" => %{}
      })

    {user, Scope.for_user(user.id)}
  end

  setup do
    # `@requirements ["app.start"]` is a no-op here (the app is running),
    # but Mix caches whether a task has run, so re-runs need clearing.
    Mix.Task.reenable("alplus.growth.report")
    :ok
  end

  test "reports no signups without implying a failing funnel" do
    output = run_report()

    assert output =~ "No attributed signups in this window."
    assert output =~ "not the same as a failing funnel"
  end

  test "reports each cluster's funnel and the activation rate" do
    # One account that reaches activation through a real check row.
    {_user, scope} = signed_up("/monitoring/cron-jobs")
    {org, owner} = org_fixture(scope)
    project = project_fixture(owner, org)
    project_scope = Scope.put_project(owner, project.id)

    monitor =
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "heartbeat", name: "Nightly"},
        action: :create,
        actor: project_scope
      )

    Repo.query!(
      """
      INSERT INTO monitor_checks
        (id, org_id, project_id, monitor_id, environment, status, latency_ms,
         checked_at, inserted_at)
      VALUES ($1, $2, $3, $4, 'production', 'up', 12, now(), now())
      """,
      [Alplus.Id.generate("chk"), org.id, project.id, monitor.id]
    )

    # One that stalls after creating a project.
    {_user2, scope2} = signed_up("/monitoring/uptime")
    {org2, owner2} = org_fixture(scope2)
    project_fixture(owner2, org2)

    output = run_report()

    assert output =~ "cron"
    assert output =~ "uptime"
    assert output =~ "TOTAL"

    # Two signups, two projects, one configured, one activated: 50%.
    assert output =~ ~r/TOTAL\s+2\s+2\s+1\s+1\s+50\.0%/

    # 50% clears the 35% target, so the report should say so rather than
    # pointing at an onboarding gap.
    assert output =~ "meets the 35.0% target"
    refute output =~ "is below the"
  end

  test "names the onboarding gap when activation misses the target" do
    # Configured but never activated: the exact case the report should
    # explain rather than just score.
    {_user, scope} = signed_up("/monitoring/cron-jobs")
    {org, owner} = org_fixture(scope)
    project = project_fixture(owner, org)

    Ash.create!(
      Monitor,
      %{org_id: org.id, project_id: project.id, type: "heartbeat", name: "Nightly"},
      action: :create,
      actor: Scope.put_project(owner, project.id)
    )

    output = run_report()

    assert output =~ "is below the 35.0% target"
    assert output =~ "pointed PostDeploy at something and never saw it work"
  end

  test "honours the --days window" do
    signed_up("/monitoring/cron-jobs")

    assert run_report(["--days", "28"]) =~ "cron"

    Mix.Task.reenable("alplus.growth.report")
    # A zero-day window starts now, so a signup a moment ago falls outside.
    assert run_report(["--days", "0"]) =~ "No attributed signups"
  end
end
