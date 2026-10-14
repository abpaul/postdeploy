defmodule AlplusWeb.ObserveActivityComponentsTest do
  use AlplusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Alplus.Sources.Source
  alias AlplusWeb.ObserveActivityComponents

  @project %{public_token: "proj_public"}

  defp source(attrs) do
    struct(
      Source,
      Map.merge(
        %{id: "src_observe", name: "API", environment: "production", status: :active},
        attrs
      )
    )
  end

  defp summary(attrs) do
    Map.merge(%{open_issues: 0, latest_release: nil, trend: []}, attrs)
  end

  test "the source chart states waiting and partial evidence, and keeps every bucket" do
    src = source(%{})

    html =
      render_component(&ObserveActivityComponents.observe_error_chart/1,
        source: src,
        summary: summary(%{}),
        window: "7d"
      )

    assert html =~ "Waiting for data"

    html =
      render_component(&ObserveActivityComponents.observe_error_chart/1,
        source: src,
        window: "30d",
        summary:
          summary(%{
            data_state: :partial,
            event_count: 2,
            step: [%{bucket: ~D[2026-01-01], event_count: 2}],
            trend: [%{bucket: ~D[2026-01-01], event_count: 2}]
          })
      )

    assert html =~ "Partial data"
    # Quiet buckets stay on the axis; nothing is compressed away.
    refute html =~ "compressed"
  end

  test "source paths keep their query overrides" do
    src = source(%{})

    assert ObserveActivityComponents.observe_source_path("org", @project, src) =~ src.id

    assert ObserveActivityComponents.observe_source_path("org", @project, src, %{
             "tab" => "issues"
           }) =~ "tab=issues"

    assert ObserveActivityComponents.observe_index_path("org", @project) =~ "observe"
    assert ObserveActivityComponents.observe_new_path("org", @project) =~ "new"
  end
end
