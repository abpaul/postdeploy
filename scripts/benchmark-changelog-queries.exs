# Run: ERL_FLAGS='+S 4' MIX_ENV=test mix test scripts/benchmark-changelog-queries.exs
# Uses local PostgreSQL, real Ash fixtures, and a rollback-only SQL sandbox.
# Measures warm LiveView pagination, including queries and HTML rendering.
# Uses 90 and 900 entries, two warmups, and 20 samples per status filter.
# Reductions measure LiveView process work; they are not CPU time.
if Mix.env() != :test or Alplus.Repo.config()[:hostname] not in ["127.0.0.1", "localhost"] do
  raise "benchmark requires MIX_ENV=test and local PostgreSQL"
end

defmodule AlplusWeb.ChangelogQueryBenchmark do
  use AlplusWeb.ConnCase, async: false

  import Alplus.OrgsFixtures
  import Phoenix.LiveViewTest
  alias Alplus.{Changelog, Mcp, Repo, Scope}
  alias Alplus.Mcp.OAuth

  @tag timeout: 120_000
  test "measure populated entry pagination", %{conn: conn} do
    user = user_fixture()
    {org, owner} = org_fixture(Scope.for_user(user.id))
    project = project_fixture(owner, org)
    actor = Scope.put_project(owner, project.id)
    Alplus.AuditFixtures.agent_audit_fixture(owner, project)

    {:ok, changelog} =
      Changelog.create_changelog(
        %{
          org_id: org.id,
          project_id: project.id,
          public_title: "Benchmark",
          public_slug: "benchmark-#{System.unique_integer([:positive])}"
        },
        actor: actor
      )

    now = DateTime.utc_now()

    {:ok, client} =
      Mcp.cache_oauth_client(
        %{
          issuer: OAuth.issuer(),
          client_id: "https://client.example/benchmark.json",
          client_name: "Benchmark",
          redirect_uris: ["https://client.example/callback"],
          fetched_at: now,
          expires_at: DateTime.add(now, 3600, :second)
        },
        authorize?: false
      )

    {:ok, grant} =
      Mcp.authorize_oauth_grant(
        %{
          org_id: org.id,
          project_id: project.id,
          user_id: user.id,
          oauth_client_id: client.id,
          issuer: OAuth.issuer(),
          resource: OAuth.resource_uri(),
          scopes: ["changelog:read"]
        },
        actor: actor
      )

    path =
      "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/public/changelog/entries"

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(user)

    results =
      for {first, last} <- [{1, 90}, {91, 900}], into: %{} do
        for n <- first..last do
          Ash.create!(
            Changelog.Entry,
            %{
              org_id: org.id,
              project_id: project.id,
              changelog_id: changelog.id,
              grant_id: grant.id,
              external_id: "benchmark-#{n}",
              title: "Benchmark entry #{n}",
              summary: "An entry for measurement.",
              status: Enum.at([:draft, :published, :archived], rem(n, 3))
            },
            actor: actor
          )
        end

        Repo.query!("ANALYZE changelog_entries")
        {:ok, view, _} = live(conn, path)
        assert has_element?(view, "#changelog-entry-list")

        measurements =
          for status <- ["", "draft"], into: %{} do
            action = fn page ->
              html = render_patch(view, path <> "?status=#{status}&page=#{page}")
              assert html =~ "Benchmark entry"
              assert has_element?(view, "#changelog-entries-pagination")
            end

            action.(1)
            action.(2)
            samples = for n <- 1..20, do: measure(view.pid, fn -> action.(rem(n, 2) + 1) end)

            {if(status == "", do: "all", else: status),
             %{
               median_ms: median(Enum.map(samples, & &1.wall_ms)),
               median_reductions: median(Enum.map(samples, & &1.reductions)),
               p95_ms: samples |> Enum.map(& &1.wall_ms) |> Enum.sort() |> Enum.at(18),
               query_counts: samples |> Enum.map(& &1.queries) |> Enum.uniq(),
               entry_query_counts: samples |> Enum.map(& &1.entry_queries) |> Enum.uniq(),
               samples: samples
             }}
          end

        GenServer.stop(view.pid)
        {last, measurements}
      end

    File.mkdir_p!(".context")
    File.write!(".context/changelog-benchmark.json", Jason.encode!(results, pretty: true))

    IO.inspect(
      results
      |> Map.new(fn {size, cases} ->
        {size, Map.new(cases, fn {name, result} -> {name, Map.delete(result, :samples)} end)}
      end),
      label: "warm pagination results",
      charlists: :as_lists
    )
  end

  defp measure(pid, action) do
    id = {__MODULE__, make_ref()}
    owner = self()

    :telemetry.attach(
      id,
      [:alplus, :repo, :query],
      fn _, _, metadata, _ ->
        if self() == pid, do: send(owner, {id, metadata.query})
      end,
      nil
    )

    try do
      {:reductions, before_reductions} = Process.info(pid, :reductions)
      {micros, _} = :timer.tc(action)
      {:reductions, after_reductions} = Process.info(pid, :reductions)
      queries = drain(id, [])
      assert queries != []

      %{
        wall_ms: micros / 1000,
        reductions: after_reductions - before_reductions,
        queries: length(queries),
        entry_queries: Enum.count(queries, &String.contains?(&1, "changelog_entries"))
      }
    after
      :telemetry.detach(id)
    end
  end

  defp drain(id, acc) do
    receive do
      {^id, query} -> drain(id, [query | acc])
    after
      0 -> acc
    end
  end

  defp median(values) do
    sorted = Enum.sort(values)
    (Enum.at(sorted, 9) + Enum.at(sorted, 10)) / 2
  end
end
