defmodule Alplus.Billing.UsageTest do
  use Alplus.DataCase, async: true

  alias Alplus.Billing.Usage
  alias Alplus.OrgsFixtures
  alias Alplus.Repo

  @now ~U[2026-08-12 12:00:00.000000Z]
  @period_start ~D[2026-08-01]

  test "returns real used/limit pairs and the right tone for each metric" do
    owner = OrgsFixtures.scope_fixture()
    {org, owner_scope} = OrgsFixtures.org_fixture(owner)

    OrgsFixtures.subscribed_fixture(org)
    projects = for _ <- 1..10, do: OrgsFixtures.project_fixture(owner_scope, org)
    seed_monitors(org, hd(projects), 80)

    seed_usage_period(org.id,
      analytics_events: 650_000,
      dropped_analytics_events: 100,
      error_events: 4_000
    )

    meters = Usage.meters(owner_scope, org.id, @now) |> Map.new(&{&1.metric, &1})

    # Structural caps never read :dropped — creation is blocked at the cap
    # elsewhere, so reaching it is "at capacity" (:notice), still error-toned.
    assert %{used: 10, limit: 10, status: :notice, tone: "error"} = meters.projects
    assert %{used: 1, limit: 5, status: :within_limit, tone: "neutral"} = meters.members
    assert %{used: 80, limit: 100, status: :warning, tone: "warning"} = meters.uptime_monitors

    assert %{
             used: 650_000,
             limit: 500_000,
             dropped: 100,
             status: :dropped,
             state: :dropped,
             tone: "error"
           } =
             meters.analytics_events

    assert %{
             used: 4_000,
             limit: 50_000,
             dropped: 0,
             status: :within_limit,
             state: :within_limit,
             tone: "neutral"
           } =
             meters.error_events
  end

  test "applies the 80/100/130 ladder at its boundaries" do
    owner = OrgsFixtures.scope_fixture()
    {org, owner_scope} = OrgsFixtures.org_fixture(owner)
    OrgsFixtures.subscribed_fixture(org)

    # The 130% ceiling reads :dropped only after a real drop occurs.
    for {used, dropped, expected_status, expected_tone} <- [
          {399_999, 0, :within_limit, "neutral"},
          {400_000, 0, :warning, "warning"},
          {499_999, 0, :warning, "warning"},
          {500_000, 0, :notice, "error"},
          {649_999, 0, :notice, "error"},
          {650_000, 0, :notice, "error"},
          {650_000, 1, :dropped, "error"}
        ] do
      seed_usage_period(org.id,
        analytics_events: used,
        dropped_analytics_events: dropped,
        error_events: 0
      )

      meter =
        owner_scope
        |> Usage.meters(org.id, @now)
        |> Enum.find(&(&1.metric == :analytics_events))

      assert meter.status == expected_status
      assert meter.tone == expected_tone
    end
  end

  test "a read-only organization with an expired trial still sees real usage" do
    {org, owner_scope} = OrgsFixtures.expired_trial_fixture(OrgsFixtures.scope_fixture())

    meters = Usage.meters(owner_scope, org.id, @now)
    projects = Enum.find(meters, &(&1.metric == :projects))

    assert projects.status == :within_limit
    assert projects.used == 0
    assert projects.limit == Alplus.Billing.Package.limit(:projects)
  end

  test "renders unavailable, not a fake zero, when the organization cannot be read" do
    owner = OrgsFixtures.scope_fixture()

    meters = Usage.meters(owner, "organization_does_not_exist", @now)

    # One unavailable meter per tracked metric: the caller still sees the
    # full list, with no fabricated numbers in it.
    assert length(meters) == 6

    for meter <- meters do
      assert meter.status == :unavailable
      assert meter.state == :unavailable
      assert meter.used == nil
      assert meter.limit == nil
      assert meter.dropped == nil
      assert meter.tone == "warning"
    end
  end

  test "refuses a cross-tenant usage read before querying the other org" do
    owner_a = OrgsFixtures.scope_fixture()
    {_org_a, scope_a} = OrgsFixtures.org_fixture(owner_a)
    owner_b = OrgsFixtures.scope_fixture()
    {org_b, _scope_b} = OrgsFixtures.org_fixture(owner_b)

    OrgsFixtures.subscribed_fixture(org_b)
    seed_usage_period(org_b.id, analytics_events: 99, error_events: 0)

    meters = Usage.meters(scope_a, org_b.id, @now)

    assert Enum.all?(meters, &(&1.status == :unavailable))
    assert Enum.all?(meters, &is_nil(&1.used))
  end

  test "refuses a forged org scope even when its cached fields match the target org" do
    owner_a = OrgsFixtures.scope_fixture()
    {_org_a, scope_a} = OrgsFixtures.org_fixture(owner_a)
    owner_b = OrgsFixtures.scope_fixture()
    {org_b, _scope_b} = OrgsFixtures.org_fixture(owner_b)

    OrgsFixtures.subscribed_fixture(org_b)
    seed_usage_period(org_b.id, analytics_events: 99, error_events: 0)

    forged_scope = %{scope_a | org_id: org_b.id, role: "owner"}
    meters = Usage.meters(forged_scope, org_b.id, @now)

    assert Enum.all?(meters, &(&1.status == :unavailable))
    assert Enum.all?(meters, &is_nil(&1.used))
  end

  defp seed_monitors(org, project, count) do
    for n <- 1..count do
      Ash.create!(
        Alplus.Monitoring.Monitor,
        %{org_id: org.id, project_id: project.id, type: "http", name: "Monitor #{n}"},
        action: :create,
        authorize?: false
      )
    end
  end

  defp seed_usage_period(org_id, attrs) do
    analytics_events = Keyword.fetch!(attrs, :analytics_events)
    dropped_analytics_events = Keyword.get(attrs, :dropped_analytics_events, 0)
    error_events = Keyword.fetch!(attrs, :error_events)
    dropped_error_events = Keyword.get(attrs, :dropped_error_events, 0)

    Repo.query!(
      """
      INSERT INTO usage_periods
        (id, org_id, period_start, analytics_events, dropped_analytics_events, error_events, dropped_error_events, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, now(), now())
      ON CONFLICT (org_id, period_start) DO UPDATE SET
        analytics_events = EXCLUDED.analytics_events,
        dropped_analytics_events = EXCLUDED.dropped_analytics_events,
        error_events = EXCLUDED.error_events,
        dropped_error_events = EXCLUDED.dropped_error_events,
        updated_at = now()
      """,
      [
        Alplus.Id.generate(:usage_period),
        org_id,
        @period_start,
        analytics_events,
        dropped_analytics_events,
        error_events,
        dropped_error_events
      ]
    )
  end
end
