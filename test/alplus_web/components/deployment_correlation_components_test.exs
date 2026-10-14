defmodule AlplusWeb.DeploymentCorrelationComponentsTest do
  use AlplusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias AlplusWeb.DeploymentCorrelationComponents

  test "renders masked unavailable values and the accessible before-after ruler" do
    window = %{
      before_start: ~U[2026-08-20 11:00:00Z],
      before_end: ~U[2026-08-20 12:00:00Z],
      release_at: ~U[2026-08-20 12:00:00Z],
      after_start: ~U[2026-08-20 12:00:00Z],
      after_end: ~U[2026-08-20 13:00:00Z],
      equal?: true,
      after_seconds: 3_600,
      expected_seconds: 3_600
    }

    coverage = %{
      before: %{coverage: 1.0, sample_count: 2},
      after: %{coverage: 0.5, sample_count: 1}
    }

    comparison = %{
      release: %{version: "v1", released_at: ~U[2026-08-20 12:00:00Z]},
      environment: "production",
      state: :partial,
      reason: :insufficient_evidence,
      window: window,
      errors: %{
        metric: %{
          before: nil,
          after: nil,
          delta: nil,
          delta_percent: nil,
          direction: :unavailable
        },
        coverage: coverage,
        state: :insufficient
      },
      monitors: [],
      measure_sources: []
    }

    html =
      render_component(&DeploymentCorrelationComponents.deployment_correlation_panel/1,
        comparison: comparison
      )

    assert html =~ "Before and after signal scale"
    assert html =~ "Release and incident time ruler"
    assert html =~ "2 samples before, 1 after"
    assert html =~ "Unavailable"
    refute html =~ "Neutral"
    refute html =~ "Better"
  end
end
