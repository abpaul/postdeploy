defmodule Alplus.Measure.VisitorStateTest do
  use ExUnit.Case, async: true

  alias Alplus.Measure.VisitorState

  test "visit state stops at its finite capacity" do
    {:ok, state} = VisitorState.start_link(name: nil, max_entries: 2)
    now = System.system_time(:millisecond)
    hit = %{type: "pageview"}

    assert %{visitors: 0, visits: 1} = VisitorState.transition(state, :first, now, hit)
    assert %{visitors: 0, visits: 1} = VisitorState.transition(state, :second, now, hit)
    assert %{visitors: 0, visits: 1} = VisitorState.transition(state, :overflow, now, hit)

    assert %{entries: 2, max_entries: 2} = VisitorState.stats(state)
  end

  test "expired visit state is reclaimed before capacity rejection" do
    {:ok, state} = VisitorState.start_link(name: nil, max_entries: 1)
    hit = %{type: "pageview"}

    assert %{visits: 1} = VisitorState.transition(state, :expired, 0, hit)
    send(state, :cleanup)
    assert %{entries: 0} = VisitorState.stats(state)
    assert %{visits: 1} = VisitorState.transition(state, :replacement, :timer.hours(1), hit)

    assert %{entries: 1} = VisitorState.stats(state)
  end

  test "visits use a strict 30-minute inactivity boundary" do
    {:ok, state} = VisitorState.start_link(name: nil)
    hit = %{type: "pageview"}

    assert %{visits: 1} = VisitorState.transition(state, :visitor, 0, hit)
    assert %{visits: 0} = VisitorState.transition(state, :visitor, :timer.minutes(10), hit)

    assert %{visits: 1} =
             VisitorState.transition(state, :visitor, :timer.minutes(41) + 1, hit)
  end
end
