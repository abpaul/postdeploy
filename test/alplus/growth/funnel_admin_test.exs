defmodule Alplus.Growth.FunnelAdminTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Growth
  alias Alplus.Growth.Funnel
  alias Alplus.Scope

  test "admin summary counts persisted product facts" do
    user = user_fixture()
    other_user = user_fixture()
    Growth.record_signup_attribution(user.id, nil)

    {org, owner_scope} = org_fixture(Scope.for_user(user.id))
    subscribed_fixture(org)
    project = project_fixture(owner_scope, org)

    sources =
      Map.new([:monitor, :observe, :measure, :changelog], fn type ->
        {source, _secret} = source_fixture(owner_scope, org, project, %{type: type})
        {type, source}
      end)

    monitor =
      Ash.create!(
        Alplus.Monitoring.Monitor,
        %{
          org_id: org.id,
          project_id: project.id,
          type: "http",
          name: "API"
        },
        action: :create,
        actor: Scope.put_project(owner_scope, project.id)
      )

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    checked_at = DateTime.add(now, -1, :day)
    since = DateTime.add(now, -30, :day)

    client =
      Ash.create!(
        Alplus.Mcp.OAuthClient,
        %{
          issuer: "https://issuer.example",
          client_id: "client",
          redirect_uris: ["https://client.example/callback"]
        },
        action: :cache,
        authorize?: false
      )

    Alplus.Repo.query!(
      """
      INSERT INTO monitor_checks
        (id, org_id, project_id, monitor_id, status, checked_at)
      VALUES ($1, $2, $3, $4, 'up', $5)
      """,
      [
        "chk_admin_summary",
        org.id,
        project.id,
        monitor.id,
        checked_at
      ]
    )

    Alplus.Repo.query!(
      """
      INSERT INTO mcp_oauth_grants
        (id, org_id, project_id, user_id, oauth_client_id, issuer, resource, scopes, last_used_at)
      VALUES ($1, $2, $3, $4, $5, 'https://issuer.example', 'https://resource.example', $6, $7)
      """,
      [
        "grant_admin_summary",
        org.id,
        project.id,
        user.id,
        client.id,
        ["observe.read"],
        checked_at
      ]
    )

    for {date, pageviews} <- [
          {DateTime.to_date(since), 99},
          {since |> DateTime.to_date() |> Date.add(1), 7}
        ] do
      Alplus.Repo.query!(
        """
        INSERT INTO analytics_days
          (id, org_id, project_id, source_id, environment, date, pageviews, visitors, visits,
           bounces, duration_seconds, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, 'production', $5, $6, 2, 3, 0, 60, $7, $7)
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          org.id,
          project.id,
          sources.measure.id,
          date,
          pageviews,
          checked_at
        ]
      )
    end

    summary = Funnel.admin_summary(since, now)

    assert summary.signups == 2
    assert summary.attributed_signups == 1
    assert summary.organizations == 1
    assert summary.configured == 1
    assert summary.activated == 1
    assert summary.mcp_grants == 1
    assert summary.mcp_used == 1
    assert summary.monitors == 1
    assert summary.sources == %{monitor: 1, observe: 1, measure: 1, changelog: 1}
    assert summary.active_orgs == %{seven_days: 1, thirty_days: 1}
    assert summary.billing == %{trial: 0, subscribed: 1}

    [organization] = Funnel.admin_organizations(since)

    assert organization.id == org.id
    assert organization.owner_email == to_string(user.email)
    assert organization.members == 1
    assert organization.projects == 1
    assert organization.monitors == 1
    assert organization.sources == %{monitor: 1, observe: 1, measure: 1, changelog: 1}
    assert organization.usage.checks == 1
    assert organization.usage.pageviews == 7
    assert organization.usage.visits == 3
    assert organization.usage.mcp_grants == 1
    assert organization.usage.mcp_used == 1
    assert organization.usage.last_signal_at == DateTime.to_naive(checked_at)

    outside_at = DateTime.add(since, -1, :second)
    inside_at = DateTime.add(since, 1, :second)

    Alplus.Repo.query!(
      """
      INSERT INTO audit_logs
        (id, org_id, actor_id, actor_kind, transport, action, subject_type, outcome, metadata,
         inserted_at)
      VALUES
        ('audit_admin_outside', $1, $2, 'user', 'session', 'test.outside', 'test', 'allowed',
         '{}'::jsonb, $3),
        ('audit_admin_inside', $1, $2, 'user', 'session', 'test.inside', 'test', 'allowed',
         '{}'::jsonb, $4)
      """,
      [org.id, other_user.id, outside_at, inside_at]
    )

    users = Funnel.admin_users(since)
    owner = Enum.find(users, &(&1.id == user.id))
    other_user_details = Enum.find(users, &(&1.id == other_user.id))

    assert owner.memberships == 1
    assert owner.roles == "owner"
    assert owner.organizations == org.name
    assert other_user_details.memberships == 0
    assert other_user_details.actions == 1
    assert other_user_details.last_active_at == DateTime.to_naive(inside_at)
  end

  test "admin detail queries enforce the 100-row ceiling" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    since = DateTime.add(now, -30, :day)
    stored_at = DateTime.to_naive(now)

    Alplus.Repo.query!(
      """
      INSERT INTO organizations
        (id, name, public_token, plan_id, plan_status, trial_ends_at, inserted_at, updated_at)
      SELECT
        'organization_admin_limit_' || n,
        'Organization ' || n,
        lpad(n::text, 16, '0'),
        'postdeploy',
        'active',
        $1,
        $2,
        $2
      FROM generate_series(1, 101) AS n
      """,
      [now, stored_at]
    )

    Alplus.Repo.query!(
      """
      INSERT INTO users (id, email, hashed_password, confirmed_at)
      SELECT
        'user_admin_limit_' || n,
        ('admin-limit-' || n || '@example.com')::citext,
        'not-used',
        $1
      FROM generate_series(1, 101) AS n
      """,
      [stored_at]
    )

    assert length(Funnel.admin_organizations(since, 1_000)) == 100
    assert length(Funnel.admin_users(since, 1_000)) == 100
  end
end
