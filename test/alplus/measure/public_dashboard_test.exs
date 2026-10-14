defmodule Alplus.Measure.PublicDashboardTest do
  use ExUnit.Case, async: true

  alias Alplus.Measure.PublicDashboard

  test "an empty selection reports empty without inventing traffic" do
    assert PublicDashboard.state_for(%{metrics: [], pages: empty_panel(), chart: empty_chart()}) ==
             :empty

    assert PublicDashboard.empty?(%{metrics: [], pages: empty_panel(), chart: empty_chart()})
  end

  test "partial dimensions remain partial even when rows are present" do
    dashboard = %{
      metrics: ["visits"],
      sources: %{
        rows: [%{label: "google.com", count: 2}],
        partial?: true,
        unavailable?: false
      }
    }

    assert PublicDashboard.state_for(dashboard) == :partial
    refute PublicDashboard.empty?(dashboard)
  end

  test "unavailable data is distinct from empty data" do
    dashboard = %{
      metrics: ["visits"],
      chart: %{trend: [], unavailable?: true, partial?: false}
    }

    assert PublicDashboard.state_for(dashboard) == :unavailable
    refute PublicDashboard.empty?(dashboard)
  end

  defp empty_chart do
    %{trend: [], unavailable?: false, partial?: false}
  end

  defp empty_panel do
    %{rows: [], unavailable?: false, partial?: false}
  end
end
