defmodule Alplus.Growth.FunnelTest do
  @moduledoc """
  The acquisition funnel, from attributed signup to activated organization.

  Each test builds the real rows a user would create, then asserts the
  funnel counts them. Asserting against an empty database would pass
  whether or not the query works, so every stage here is reached by
  actually creating the thing that defines it.
  """

  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Growth
  alias Alplus.Growth.Funnel
  alias Alplus.Monitoring.Monitor
  alias Alplus.Scope

  defp since, do: DateTime.add(DateTime.utc_now(), -1, :hour)

  # Registers a user, attributes them to `cluster`'s landing page, and
  # returns the pieces needed to advance them through the funnel.
  defp signed_up(landing_page) do
    user = user_fixture()
    scope = Scope.for_user(user.id)

    :ok =
      Growth.record_signup_attribution(user.id, %{
        "landing_page" => landing_page,
        "referrer_host" => "www.google.com",
        "utm" => %{}
      })

    %{user: user, scope: scope}
  end

  defp with_project(%{scope: scope} = context) do
    {org, owner_scope} = org_fixture(scope)
    project = project_fixture(owner_scope, org)

    context
    |> Map.put(:org, org)
    |> Map.put(:project, project)
    |> Map.put(:scope, Scope.put_project(owner_scope, project.id))
  end

  defp with_monitor(%{org: org, project: project, scope: scope} = context) do
    monitor =
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "heartbeat", name: "Nightly"},
        action: :create,
        actor: scope
      )

    Map.put(context, :monitor, monitor)
  end

  # A check row is the canonical activation event: the first moment PostDeploy did
  # something for the user rather than the user configuring PostDeploy.
  defp with_check(%{org: org, project: project, monitor: monitor} = context) do
    Repo.query!(
      """
      INSERT INTO monitor_checks
        (id, org_id, project_id, monitor_id, environment, status, latency_ms,
         checked_at, inserted_at)
      VALUES ($1, $2, $3, $4, 'production', 'up', 12, now(), now())
      """,
      [Alplus.Id.generate("chk"), org.id, project.id, monitor.id]
    )

    context
  end

  describe "funnel stages" do
    test "a signup with nothing set up counts only as a signup" do
      signed_up("/monitoring/cron-jobs")

      assert %{signups: 1, projects: 0, configured: 0, activated: 0} =
               Funnel.by_cluster(since())["cron"]
    end

    test "creating a project advances the project stage only" do
      signed_up("/monitoring/cron-jobs") |> with_project()

      assert %{signups: 1, projects: 1, configured: 0, activated: 0} =
               Funnel.by_cluster(since())["cron"]
    end

    test "creating a monitor advances configured, but not activated" do
      signed_up("/monitoring/cron-jobs") |> with_project() |> with_monitor()

      # Configuring a monitor is the user doing work for PostDeploy. Nothing has
      # been observed yet, so this is deliberately not activation.
      assert %{signups: 1, projects: 1, configured: 1, activated: 0} =
               Funnel.by_cluster(since())["cron"]
    end

    test "a real check result activates the account" do
      signed_up("/guides/kubernetes-cronjob-heartbeat")
      |> with_project()
      |> with_monitor()
      |> with_check()

      assert %{signups: 1, projects: 1, configured: 1, activated: 1} =
               Funnel.by_cluster(since())["cron"]
    end
  end

  describe "cluster attribution" do
    test "keeps clusters separate and totals them correctly" do
      signed_up("/monitoring/cron-jobs") |> with_project() |> with_monitor() |> with_check()
      signed_up("/monitoring/uptime") |> with_project()
      signed_up("/alternatives/cronitor")

      by_cluster = Funnel.by_cluster(since())

      assert %{signups: 1, activated: 1} = by_cluster["cron"]
      assert %{signups: 1, projects: 1, activated: 0} = by_cluster["uptime"]
      assert %{signups: 1, projects: 0} = by_cluster["comparison"]

      assert %{signups: 3, projects: 2, configured: 1, activated: 1} = Funnel.totals(since())
    end

    test "excludes signups from before the window" do
      signed_up("/monitoring/cron-jobs")

      # A window starting in the future contains nothing.
      future = DateTime.add(DateTime.utc_now(), 1, :hour)
      assert Funnel.by_cluster(future) == %{}
    end
  end

  describe "activation rate" do
    test "is nil rather than zero when nobody has signed up" do
      # "No data" and "nobody activated" are different facts. Reporting 0%
      # for an empty week invites the wrong conclusion.
      assert Funnel.activation_rate(%{signups: 0, activated: 0}) == nil
      assert Funnel.activation_vs_target(%{signups: 0, activated: 0}) == :no_data
    end

    test "compares against the configured target" do
      assert Funnel.activation_rate(%{signups: 4, activated: 1}) == 0.25

      # The default target is 35%.
      assert {:ok, %{meets_target?: false, target: 0.35}} =
               Funnel.activation_vs_target(%{signups: 4, activated: 1})

      assert {:ok, %{meets_target?: true}} =
               Funnel.activation_vs_target(%{signups: 4, activated: 2})
    end
  end
end
