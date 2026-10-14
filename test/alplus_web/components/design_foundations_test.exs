defmodule AlplusWeb.CoreComponents.DesignFoundationsTest do
  @moduledoc "Behavior tests for the approved ruler primitive."

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import AlplusWeb.CoreComponents, only: [ruler: 1]

  defp render_html(component, assigns) do
    rendered_to_string(component.(Map.put(assigns, :__changed__, nil)))
  end

  test "ruler exposes visible labels and named valid markers" do
    html =
      render_html(&ruler/1, %{
        labels: ["12:00", "12:30", "now"],
        label: "Deploy timeline",
        markers: [%{position: 42, label: "deploy v2.4.1", kind: :deploy}]
      })

    assert html =~ ~s(role="group")
    assert html =~ ~s(aria-label="Deploy timeline")
    assert html =~ "12:00"
    assert html =~ ~s(data-kind="deploy")
    assert html =~ ~s(style="left: 42%")
    assert html =~ ~s(aria-label="deploy v2.4.1")
  end

  test "ruler ignores markers outside its measured range" do
    html =
      render_html(&ruler/1, %{
        labels: ["start", "end"],
        markers: [%{position: 101, label: "invalid"}]
      })

    refute html =~ "invalid"
    refute html =~ ~s(role="img")
  end

  test "ruler rejects a scale without a non-empty visible label" do
    assert_raise ArgumentError, ~r/requires at least one non-empty visible label/, fn ->
      render_html(&ruler/1, %{labels: []})
    end

    assert_raise ArgumentError, ~r/requires at least one non-empty visible label/, fn ->
      render_html(&ruler/1, %{labels: ["", "  ", "\n"]})
    end
  end
end
