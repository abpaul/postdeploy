defmodule Alplus.Measure.AnalyticsEngineTest do
  use ExUnit.Case, async: false

  alias Alplus.Measure.AnalyticsEngine

  setup do
    :ok = Alplus.Measure.AnalyticsEngine.Batcher.flush()
    :ok = Alplus.Measure.AnalyticsEngine.DevAdapter.clear()
  end

  test "the bounded batcher sends privacy-safe aggregate points to the dev adapter" do
    hour = DateTime.utc_now() |> DateTime.truncate(:second)
    point = point(hour)

    assert :ok = AnalyticsEngine.record(point)

    assert :ok =
             AnalyticsEngine.record(%{point | pageviews: 2, visitors: 0, visits: 1, bounces: 0})

    assert :ok = Alplus.Measure.AnalyticsEngine.Batcher.flush()

    assert {:ok, [stored]} =
             AnalyticsEngine.recent(point.source_id, DateTime.add(hour, -1, :second))

    assert stored.pageviews == 3
    assert stored.visitors == 1
    assert stored.visits == 2
    assert stored.bounces == 1
  end

  test "the AE boundary rejects raw request fields before they reach its buffer" do
    assert_raise ArgumentError, ~r/privacy-safe aggregate fields/, fn ->
      AnalyticsEngine.record(Map.put(point(DateTime.utc_now()), :user_agent, "never persist"))
    end
  end

  test "recent reads are source-scoped, never a sibling site's, even inside one project" do
    hour = DateTime.utc_now() |> DateTime.truncate(:second)
    first = point(hour)
    second = %{first | source_id: "source_00000000000000000000000000"}

    assert :ok = AnalyticsEngine.record(first)
    assert :ok = AnalyticsEngine.record(second)
    assert :ok = Alplus.Measure.AnalyticsEngine.Batcher.flush()

    assert {:ok, [stored]} =
             AnalyticsEngine.recent(first.source_id, DateTime.add(hour, -1, :second))

    assert stored.source_id == first.source_id
  end

  test "recent_many batches several sites in one call without cross-contamination" do
    hour = DateTime.utc_now() |> DateTime.truncate(:second)
    first = point(hour)
    second = %{first | source_id: "source_00000000000000000000000000"}
    third = %{first | source_id: "source_11111111111111111111111111"}

    assert :ok = AnalyticsEngine.record(first)
    assert :ok = AnalyticsEngine.record(second)
    assert :ok = Alplus.Measure.AnalyticsEngine.Batcher.flush()

    assert {:ok, by_source} =
             AnalyticsEngine.recent_many(
               [first.source_id, second.source_id, third.source_id],
               DateTime.add(hour, -1, :second)
             )

    assert [%{source_id: id}] = by_source[first.source_id]
    assert id == first.source_id
    assert [%{source_id: id}] = by_source[second.source_id]
    assert id == second.source_id
    assert by_source[third.source_id] == []
  end

  test "a flush against the unconfigured adapter drops the buffer without crashing the batcher" do
    original_adapter = Application.fetch_env!(:alplus, :analytics_engine_adapter)
    Application.put_env(:alplus, :analytics_engine_adapter, AnalyticsEngine.UnavailableAdapter)

    on_exit(fn ->
      Application.put_env(:alplus, :analytics_engine_adapter, original_adapter)
    end)

    batcher_pid = Process.whereis(Alplus.Measure.AnalyticsEngine.Batcher)

    assert :ok = AnalyticsEngine.record(point(DateTime.utc_now() |> DateTime.truncate(:second)))
    assert :ok = Alplus.Measure.AnalyticsEngine.Batcher.flush()

    assert Process.alive?(batcher_pid)
    assert Alplus.Measure.AnalyticsEngine.Batcher.depth() == 0
  end

  test "the public buffer remains bounded while its consumer cannot run" do
    batcher = Process.whereis(Alplus.Measure.AnalyticsEngine.Batcher)
    :ok = :sys.suspend(batcher)

    on_exit(fn ->
      if Process.alive?(batcher), do: :sys.resume(batcher)
    end)

    for _point <- 1..1_100 do
      assert :ok = AnalyticsEngine.record(point(DateTime.utc_now() |> DateTime.truncate(:second)))
    end

    assert Alplus.Measure.AnalyticsEngine.Batcher.depth() == 1_000

    :ok = :sys.resume(batcher)
    assert :ok = Alplus.Measure.AnalyticsEngine.Batcher.flush()
  end

  defp point(hour) do
    %{
      org_id: "org_01j2x3y4z5abcdefghjkmnpqrs",
      project_id: "proj_01j2x3y4z5abcdefghjkmnpqrs",
      source_id: "source_01j2x3y4z5abcdefghjkmnpqrs",
      hour: hour,
      pageviews: 1,
      visitors: 1,
      visits: 1,
      bounces: 1,
      duration_seconds: 0
    }
  end
end
