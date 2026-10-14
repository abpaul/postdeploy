defmodule AlplusWeb.ProjectSignalsTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias AlplusWeb.ProjectSignals
  alias Alplus.Sources.Source

  test "batch signals keep mixed-organization project ids isolated" do
    owner_a = user_fixture()
    {org_a, scope_a} = org_fixture(Alplus.Scope.for_user(owner_a.id))
    project_a = project_fixture(scope_a, org_a)
    {source_a, _} = source_fixture(scope_a, org_a, project_a)

    owner_b = user_fixture()
    {org_b, scope_b} = org_fixture(Alplus.Scope.for_user(owner_b.id))
    project_b = project_fixture(scope_b, org_b)
    {source_b, _} = source_fixture(scope_b, org_b, project_b)

    signals = ProjectSignals.load_many([project_a, project_b], scope_a)

    assert Map.keys(signals) == [project_a.id]
    assert signals[project_a.id].observe.state == :empty
    refute Map.has_key?(signals, project_b.id)

    sources =
      Source
      |> Ash.Query.for_read(
        :list_for_projects,
        %{project_ids: [project_a.id, project_b.id]},
        actor: scope_a
      )
      |> Ash.read!(actor: scope_a)

    assert Enum.map(sources, & &1.id) == [source_a.id]
    refute Enum.any?(sources, &(&1.id == source_b.id))
  end

  test "batch signals use a fixed number of reads for fifty projects" do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    subscribed_fixture(org)

    # Five times the plan's project limit, seeded directly, so a per-project
    # read cannot hide inside the query budget.
    projects =
      for n <- 1..50 do
        Ash.Seed.seed!(Alplus.Projects.Project, %{
          org_id: org.id,
          name: "Project #{n}",
          slug: "project-#{n}"
        })
      end

    telemetry_id = {__MODULE__, self(), System.unique_integer([:positive])}

    :telemetry.attach(
      telemetry_id,
      [:alplus, :repo, :query],
      fn _event, _measurements, _metadata, pid ->
        send(pid, :project_signal_batch_query)
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    signals = ProjectSignals.load_many(projects, scope)
    query_count = collect_query_count()

    assert map_size(signals) == 50
    assert query_count <= 10
  end

  test "unavailable fallback keeps every pillar explicit" do
    signals = ProjectSignals.unavailable()

    assert signals.monitor.state == :unavailable
    assert signals.observe.state == :unavailable
    assert signals.measure.state == :unavailable
    assert signals.measure.pageviews == nil
  end

  defp collect_query_count(count \\ 0) do
    receive do
      :project_signal_batch_query -> collect_query_count(count + 1)
    after
      100 -> count
    end
  end
end
