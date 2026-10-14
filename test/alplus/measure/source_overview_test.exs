defmodule Alplus.Measure.SourceOverviewTest do
  use ExUnit.Case, async: true

  alias Alplus.Measure.SourceOverview
  alias Alplus.Projects.ProjectDomain
  alias Alplus.Sources.Source

  defp source(id, attrs) do
    struct(
      Source,
      Map.merge(
        %{
          id: id,
          name: id,
          hostname: "#{id}.example.com",
          environment: "production",
          status: :active,
          measure_token: "msr_#{id}"
        },
        attrs
      )
    )
  end

  defp summary(attrs \\ %{}) do
    Map.merge(
      %{
        totals: %{pageviews: 0, visitors: 0, visits: 0},
        trend: [],
        data_source: "PostgreSQL rollups",
        data_source_key: :postgres_rollup,
        fallback?: false,
        unavailable?: false,
        evidence?: false,
        evidence: %{}
      },
      attrs
    )
  end

  defp domain(hostname, attrs \\ %{}) do
    struct(
      ProjectDomain,
      Map.merge(%{id: "domain_#{hostname}", hostname: hostname}, attrs)
    )
  end

  test "keeps same-environment sites separate and joins each hostname" do
    first = source("first", %{hostname: "app.example.com"})
    second = source("second", %{hostname: "docs.example.com"})
    domains = [domain("app.example.com"), domain("docs.example.com")]

    overviews =
      SourceOverview.build(
        [first, second],
        %{
          first.id => summary(%{totals: %{pageviews: 2, visitors: 1, visits: 1}}),
          second.id => summary(%{totals: %{pageviews: 5, visitors: 3, visits: 3}})
        },
        domains
      )

    assert Enum.map(overviews, & &1.identity.hostname) == ["app.example.com", "docs.example.com"]
    assert Enum.map(overviews, & &1.identity.environment) == ["production", "production"]
    assert Enum.map(overviews, & &1.domain.state) == [:allowlisted, :allowlisted]
    assert Enum.map(overviews, & &1.recent.pageviews) == [2, 5]
  end

  test "distinguishes not installed, installed waiting, zero traffic, and receiving" do
    not_installed = source("not-installed", %{hostname: "not-installed.example.com"})
    waiting = source("waiting", %{hostname: "waiting.example.com"})
    zero = source("zero", %{hostname: "zero.example.com"})
    receiving = source("receiving", %{hostname: "receiving.example.com"})

    domains = [
      domain("waiting.example.com"),
      domain("zero.example.com"),
      domain("receiving.example.com")
    ]

    overviews =
      SourceOverview.build(
        [not_installed, waiting, zero, receiving],
        %{
          not_installed.id => summary(),
          waiting.id => summary(),
          zero.id =>
            summary(%{
              totals: %{pageviews: 0, visitors: 0, visits: 0},
              evidence?: true,
              evidence: %{first_pageview_on: ~D[2026-08-20], last_pageview_on: ~D[2026-08-20]}
            }),
          receiving.id => summary(%{totals: %{pageviews: 3, visitors: 2, visits: 2}})
        },
        domains
      )

    assert Enum.map(overviews, & &1.installation_state) == [
             :not_installed,
             :installed_waiting,
             :zero_traffic,
             :receiving
           ]
  end

  test "does not join an allowlist row from a sibling tenant or project" do
    source =
      source("scoped", %{
        org_id: "org_a",
        project_id: "project_a",
        hostname: "app.example.com"
      })

    [overview] =
      SourceOverview.build(
        [source],
        %{source.id => summary()},
        [domain("app.example.com", %{org_id: "org_b", project_id: "project_b"})]
      )

    assert overview.domain.state == :missing
    refute overview.domain.configured?
    assert overview.installation_state == :not_installed
  end

  test "keeps durable-rollup fallback distinct from unavailable analytics" do
    source = source("fallback", %{hostname: "fallback.example.com"})
    domains = [domain("fallback.example.com")]

    [fallback] =
      SourceOverview.build(
        [source],
        %{
          source.id =>
            summary(%{
              totals: %{pageviews: 4, visitors: 2, visits: 2},
              data_source: "PostgreSQL rollups",
              fallback?: true,
              analytics_engine_unavailable?: true,
              evidence?: true
            })
        },
        domains
      )

    assert fallback.installation_state == :receiving
    assert fallback.fallback?
    refute fallback.unavailable?
    assert fallback.data_source == "PostgreSQL rollups"

    [unavailable] =
      SourceOverview.build(
        [source],
        %{source.id => summary(%{unavailable?: true})},
        domains
      )

    assert unavailable.installation_state == :unavailable
    assert unavailable.unavailable?
  end

  test "revocation removes usable token and setup actions" do
    source = source("revoked", %{status: :revoked, hostname: "revoked.example.com"})

    [overview] =
      SourceOverview.build(
        [source],
        %{source.id => summary()},
        [domain("revoked.example.com")]
      )

    assert overview.token.state == :revoked
    assert overview.token.value == nil
    assert overview.installation_state == :revoked
    refute overview.actions.copy_snippet?
    refute overview.actions.rotate?
    refute overview.actions.revoke?
  end
end
