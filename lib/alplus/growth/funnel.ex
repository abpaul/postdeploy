defmodule Alplus.Growth.Funnel do
  @moduledoc """
  The acquisition funnel, from landing page to activated organization.

  ## What activation means here

  Activation is not "registered". A registration that never produces a
  monitored event is a row in a users table, not a customer, and counting
  it as success is how a growth program fools itself.

  The stages below deliberately mirror `AlplusWeb.Onboarding`'s checklist,
  which the product already derives from real persisted rows rather than a
  stored completion flag. Reusing that definition means the funnel and the
  in-product checklist can never disagree about what "set up" means:

  1. `signup` — the account exists.
  2. `project` — a project exists in an org the user belongs to.
  3. `configured` — a monitor, source, or verified domain exists, so the
     user has actually pointed PostDeploy at something.
  4. `activated` — a real signal arrived: a check result, an error issue,
     or a day of analytics. **This is the canonical activation event.**

  Stage 4 is the one that matters, because it is the first moment PostDeploy did
  something for the user rather than the user doing something for PostDeploy.

  ## Why this reads Postgres directly

  This is cross-tenant aggregate reporting: it counts across every
  organization at once and belongs to no tenant, so there is no actor whose
  policies could scope it. Every Ash read path here is deliberately
  project-scoped and would return nothing. The queries are read-only
  aggregates over indexed foreign keys, they take no user input beyond a
  time window, and they are listed in `docs/DIRECT-ECTO-ESCAPE-HATCHES.md`.

  The cross-tenant aggregates also power the founder's internal dashboard.
  """

  alias Alplus.Repo

  @type stage_counts :: %{
          signups: non_neg_integer(),
          projects: non_neg_integer(),
          configured: non_neg_integer(),
          activated: non_neg_integer()
        }

  @doc """
  Funnel counts for accounts created since `since`, keyed by the content
  cluster their signup was attributed to.

  Every stage counts *users*, so the stages are directly comparable and a
  rate is a real proportion rather than a ratio of unlike things. A user is
  counted at a stage when any organization they belong to reached it.
  """
  @spec by_cluster(DateTime.t()) :: %{String.t() => stage_counts()}
  def by_cluster(%DateTime{} = since) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH attributed AS (
          SELECT a.user_id, a.content_cluster
          FROM growth_signup_attributions a
          WHERE a.inserted_at >= $1
        ),
        -- One row per user per stage reached, via any org they belong to.
        reached AS (
          SELECT
            att.user_id,
            att.content_cluster,
            bool_or(p.id IS NOT NULL) AS has_project,
            bool_or(
              mon.id IS NOT NULL OR src.id IS NOT NULL OR dom.id IS NOT NULL
            ) AS configured,
            bool_or(
              chk.id IS NOT NULL OR iss.id IS NOT NULL OR ad.id IS NOT NULL
            ) AS activated
          FROM attributed att
          LEFT JOIN memberships m ON m.user_id = att.user_id
          LEFT JOIN projects p ON p.org_id = m.org_id
          LEFT JOIN monitors mon ON mon.project_id = p.id
          LEFT JOIN sources src ON src.project_id = p.id
          LEFT JOIN project_domains dom ON dom.project_id = p.id
          LEFT JOIN monitor_checks chk ON chk.project_id = p.id
          LEFT JOIN issues iss ON iss.project_id = p.id
          LEFT JOIN analytics_days ad ON ad.project_id = p.id
          GROUP BY att.user_id, att.content_cluster
        )
        SELECT
          content_cluster,
          count(*) AS signups,
          count(*) FILTER (WHERE has_project) AS projects,
          count(*) FILTER (WHERE configured) AS configured,
          count(*) FILTER (WHERE activated) AS activated
        FROM reached
        GROUP BY content_cluster
        ORDER BY content_cluster
        """,
        [since]
      )

    Map.new(rows, fn [cluster, signups, projects, configured, activated] ->
      {cluster,
       %{
         signups: signups,
         projects: projects,
         configured: configured,
         activated: activated
       }}
    end)
  end

  @doc """
  The same funnel totalled across every cluster.
  """
  @spec totals(DateTime.t()) :: stage_counts()
  def totals(%DateTime{} = since) do
    since
    |> by_cluster()
    |> Map.values()
    |> Enum.reduce(
      %{signups: 0, projects: 0, configured: 0, activated: 0},
      fn counts, acc ->
        Map.merge(acc, counts, fn _key, a, b -> a + b end)
      end
    )
  end

  @doc """
  Signup-to-activation rate for a set of counts, or `nil` when there are no
  signups.

  `nil` rather than `0.0` on an empty denominator: "no data" and "nobody
  activated" are different facts, and a report that shows 0% for an empty
  week invites the wrong conclusion.
  """
  def activation_rate(%{signups: 0}), do: nil
  def activation_rate(%{signups: signups, activated: activated}), do: activated / signups

  @doc """
  The five website-health-check stages for journeys started since `since`.
  """
  @spec health_check(DateTime.t()) :: %{String.t() => non_neg_integer()}
  def health_check(%DateTime{} = since), do: Alplus.Growth.HealthCheck.counts(since)

  @doc """
  Compares the measured activation rate against the configured target.

  Returns `:no_data` rather than a verdict when nothing has happened yet,
  so a fresh install never reports a failing funnel.
  """
  @spec activation_vs_target(stage_counts()) ::
          {:ok, %{rate: float(), target: float(), meets_target?: boolean()}} | :no_data
  def activation_vs_target(counts) do
    case activation_rate(counts) do
      nil ->
        :no_data

      rate ->
        target = Alplus.Growth.targets().signup_to_activation_rate
        {:ok, %{rate: rate, target: target, meets_target?: rate >= target}}
    end
  end

  @doc "Returns founder-only product counts for the selected window."
  @spec admin_summary(DateTime.t(), DateTime.t()) :: map()
  def admin_summary(%DateTime{} = since, %DateTime{} = now) do
    active_7d = DateTime.add(now, -7, :day)
    active_30d = DateTime.add(now, -30, :day)

    %{
      rows: [
        [
          signups,
          attributed_signups,
          organizations,
          configured,
          activated,
          mcp_grants,
          mcp_used,
          monitors,
          monitor_sources,
          observe_sources,
          measure_sources,
          changelog_sources,
          active_orgs_7d,
          active_orgs_30d,
          trial_orgs,
          subscribed_orgs
        ]
      ]
    } =
      Repo.query!(
        """
        SELECT
          (SELECT count(*) FROM users),
          (SELECT count(*) FROM growth_signup_attributions WHERE inserted_at >= $1),
          (SELECT count(*) FROM organizations),
          (
            SELECT count(*)
            FROM organizations o
            WHERE EXISTS (
              SELECT 1 FROM projects p
              JOIN monitors m ON m.project_id = p.id
              WHERE p.org_id = o.id
            )
            OR EXISTS (
              SELECT 1 FROM projects p
              JOIN sources s ON s.project_id = p.id
              WHERE p.org_id = o.id
            )
            OR EXISTS (
              SELECT 1 FROM projects p
              JOIN project_domains d ON d.project_id = p.id
              WHERE p.org_id = o.id
            )
          ),
          (
            SELECT count(*)
            FROM organizations o
            WHERE EXISTS (
              SELECT 1 FROM monitor_checks c WHERE c.org_id = o.id
            )
            OR EXISTS (
              SELECT 1 FROM issues i WHERE i.org_id = o.id
            )
            OR EXISTS (
              SELECT 1 FROM analytics_days a WHERE a.org_id = o.id
            )
          ),
          (SELECT count(*) FROM mcp_oauth_grants WHERE revoked_at IS NULL),
          (SELECT count(*) FROM mcp_oauth_grants WHERE revoked_at IS NULL AND last_used_at IS NOT NULL),
          (SELECT count(*) FROM monitors),
          (SELECT count(*) FROM sources WHERE type = 'monitor'),
          (SELECT count(*) FROM sources WHERE type = 'observe'),
          (SELECT count(*) FROM sources WHERE type = 'measure'),
          (SELECT count(*) FROM sources WHERE type = 'changelog'),
          (
            SELECT count(*)
            FROM organizations o
            WHERE EXISTS (
              SELECT 1 FROM monitor_checks c
              WHERE c.org_id = o.id AND c.checked_at >= $2
            )
            OR EXISTS (
              SELECT 1 FROM issues i
              WHERE i.org_id = o.id AND i.last_seen_at >= $2
            )
            OR EXISTS (
              SELECT 1 FROM analytics_days a
              WHERE a.org_id = o.id AND a.date >= $2::date
            )
            OR EXISTS (
              SELECT 1 FROM mcp_oauth_grants g
              WHERE g.org_id = o.id AND g.last_used_at >= $2
            )
          ),
          (
            SELECT count(*)
            FROM organizations o
            WHERE EXISTS (
              SELECT 1 FROM monitor_checks c
              WHERE c.org_id = o.id AND c.checked_at >= $3
            )
            OR EXISTS (
              SELECT 1 FROM issues i
              WHERE i.org_id = o.id AND i.last_seen_at >= $3
            )
            OR EXISTS (
              SELECT 1 FROM analytics_days a
              WHERE a.org_id = o.id AND a.date >= $3::date
            )
            OR EXISTS (
              SELECT 1 FROM mcp_oauth_grants g
              WHERE g.org_id = o.id AND g.last_used_at >= $3
            )
          ),
          (SELECT count(*) FROM organizations WHERE plan_status = 'trialing'),
          (SELECT count(*) FROM organizations WHERE plan_status IN ('active', 'past_due'))
        """,
        [since, active_7d, active_30d]
      )

    %{
      signups: signups,
      attributed_signups: attributed_signups,
      organizations: organizations,
      configured: configured,
      activated: activated,
      mcp_grants: mcp_grants,
      mcp_used: mcp_used,
      monitors: monitors,
      sources: %{
        monitor: monitor_sources,
        observe: observe_sources,
        measure: measure_sources,
        changelog: changelog_sources
      },
      active_orgs: %{seven_days: active_orgs_7d, thirty_days: active_orgs_30d},
      billing: %{trial: trial_orgs, subscribed: subscribed_orgs}
    }
  end

  @doc "Returns organization-level product and usage details for the founder admin."
  @spec admin_organizations(DateTime.t(), pos_integer()) :: [map()]
  def admin_organizations(%DateTime{} = since, limit \\ 100) when limit > 0 do
    limit = min(limit, 100)

    %{rows: rows} =
      Repo.query!(
        """
        WITH membership_stats AS (
          SELECT
            m.org_id,
            count(*) AS members,
            max(u.email::text) FILTER (WHERE m.role = 'owner') AS owner_email
          FROM memberships m
          JOIN users u ON u.id = m.user_id
          GROUP BY m.org_id
        ),
        project_stats AS (
          SELECT org_id, count(*) AS projects
          FROM projects
          GROUP BY org_id
        ),
        monitor_stats AS (
          SELECT org_id, count(*) AS monitors
          FROM monitors
          GROUP BY org_id
        ),
        source_stats AS (
          SELECT
            org_id,
            count(*) FILTER (WHERE type = 'monitor') AS monitor_sources,
            count(*) FILTER (WHERE type = 'observe') AS observe_sources,
            count(*) FILTER (WHERE type = 'measure') AS measure_sources,
            count(*) FILTER (WHERE type = 'changelog') AS changelog_sources
          FROM sources
          GROUP BY org_id
        ),
        check_usage AS (
          SELECT org_id, count(*) AS checks, max(checked_at) AS last_check_at
          FROM monitor_checks
          WHERE checked_at >= $1
          GROUP BY org_id
        ),
        issue_usage AS (
          SELECT org_id, count(*) AS issues, max(last_seen_at) AS last_issue_at
          FROM issues
          WHERE last_seen_at >= $1
          GROUP BY org_id
        ),
        measure_usage AS (
          SELECT
            org_id,
            coalesce(sum(pageviews), 0)::bigint AS pageviews,
            coalesce(sum(visits), 0)::bigint AS visits,
            max(updated_at) AS last_measure_at
          FROM analytics_days
          WHERE date > $1::date
          GROUP BY org_id
        ),
        mcp_usage AS (
          SELECT
            org_id,
            count(*) FILTER (WHERE revoked_at IS NULL) AS grants,
            count(*) FILTER (
              WHERE revoked_at IS NULL AND last_used_at >= $1
            ) AS used_grants,
            max(last_used_at) FILTER (
              WHERE revoked_at IS NULL AND last_used_at >= $1
            ) AS last_mcp_at
          FROM mcp_oauth_grants
          GROUP BY org_id
        )
        SELECT
          o.id,
          o.name,
          o.public_token,
          o.plan_status::text,
          o.trial_ends_at,
          o.inserted_at,
          coalesce(ms.members, 0),
          ms.owner_email,
          coalesce(ps.projects, 0),
          coalesce(mos.monitors, 0),
          coalesce(ss.monitor_sources, 0),
          coalesce(ss.observe_sources, 0),
          coalesce(ss.measure_sources, 0),
          coalesce(ss.changelog_sources, 0),
          coalesce(cu.checks, 0),
          coalesce(iu.issues, 0),
          coalesce(meu.pageviews, 0),
          coalesce(meu.visits, 0),
          coalesce(mu.grants, 0),
          coalesce(mu.used_grants, 0),
          greatest(cu.last_check_at, iu.last_issue_at, meu.last_measure_at, mu.last_mcp_at)
            AS last_signal_at
        FROM organizations o
        LEFT JOIN membership_stats ms ON ms.org_id = o.id
        LEFT JOIN project_stats ps ON ps.org_id = o.id
        LEFT JOIN monitor_stats mos ON mos.org_id = o.id
        LEFT JOIN source_stats ss ON ss.org_id = o.id
        LEFT JOIN check_usage cu ON cu.org_id = o.id
        LEFT JOIN issue_usage iu ON iu.org_id = o.id
        LEFT JOIN measure_usage meu ON meu.org_id = o.id
        LEFT JOIN mcp_usage mu ON mu.org_id = o.id
        ORDER BY last_signal_at DESC NULLS LAST, o.inserted_at DESC
        LIMIT $2
        """,
        [since, limit]
      )

    Enum.map(rows, fn [
                        id,
                        name,
                        public_token,
                        billing_status,
                        trial_ends_at,
                        inserted_at,
                        members,
                        owner_email,
                        projects,
                        monitors,
                        monitor_sources,
                        observe_sources,
                        measure_sources,
                        changelog_sources,
                        checks,
                        issues,
                        pageviews,
                        visits,
                        mcp_grants,
                        mcp_used,
                        last_signal_at
                      ] ->
      %{
        id: id,
        name: name,
        public_token: public_token,
        billing_status: billing_status,
        trial_ends_at: trial_ends_at,
        inserted_at: inserted_at,
        members: members,
        owner_email: owner_email,
        projects: projects,
        monitors: monitors,
        sources: %{
          monitor: monitor_sources,
          observe: observe_sources,
          measure: measure_sources,
          changelog: changelog_sources
        },
        usage: %{
          checks: checks,
          issues: issues,
          pageviews: pageviews,
          visits: visits,
          mcp_grants: mcp_grants,
          mcp_used: mcp_used,
          last_signal_at: last_signal_at
        }
      }
    end)
  end

  @doc "Returns user membership and recent activity details for the founder admin."
  @spec admin_users(DateTime.t(), pos_integer()) :: [map()]
  def admin_users(%DateTime{} = since, limit \\ 100) when limit > 0 do
    limit = min(limit, 100)

    %{rows: rows} =
      Repo.query!(
        """
        WITH membership_stats AS (
          SELECT
            m.user_id,
            count(*) AS memberships,
            string_agg(DISTINCT m.role, ', ' ORDER BY m.role) AS roles,
            string_agg(DISTINCT o.name, ', ' ORDER BY o.name) AS organizations
          FROM memberships m
          JOIN organizations o ON o.id = m.org_id
          GROUP BY m.user_id
        ),
        activity_stats AS (
          SELECT actor_id, count(*) AS actions, max(inserted_at) AS last_active_at
          FROM audit_logs
          WHERE inserted_at >= $1
          GROUP BY actor_id
        )
        SELECT
          u.id,
          u.email::text,
          u.name,
          u.confirmed_at,
          coalesce(ms.memberships, 0),
          coalesce(ms.roles, ''),
          coalesce(ms.organizations, ''),
          coalesce(a.actions, 0),
          a.last_active_at
        FROM users u
        LEFT JOIN membership_stats ms ON ms.user_id = u.id
        LEFT JOIN activity_stats a ON a.actor_id = u.id
        ORDER BY a.last_active_at DESC NULLS LAST, u.email
        LIMIT $2
        """,
        [since, limit]
      )

    Enum.map(rows, fn [
                        id,
                        email,
                        name,
                        confirmed_at,
                        memberships,
                        roles,
                        organizations,
                        actions,
                        last_active_at
                      ] ->
      %{
        id: id,
        email: email,
        name: name,
        confirmed_at: confirmed_at,
        memberships: memberships,
        roles: roles,
        organizations: organizations,
        actions: actions,
        last_active_at: last_active_at
      }
    end)
  end

  @doc "Returns the first-party Observe path when a vendor project is designated."
  @spec dogfood_observe_path() :: String.t() | nil
  def dogfood_observe_path do
    case Repo.query!("""
         SELECT o.public_token, p.public_token
         FROM changelogs c
         JOIN organizations o ON o.id = c.org_id
         JOIN projects p ON p.id = c.project_id
         WHERE c."vendor?" IS TRUE
           AND o.public_token IS NOT NULL
           AND p.public_token IS NOT NULL
         LIMIT 1
         """).rows do
      [[org_token, project_token]] ->
        "/dashboard/orgs/#{org_token}/projects/#{project_token}/observe"

      [] ->
        nil
    end
  end
end
