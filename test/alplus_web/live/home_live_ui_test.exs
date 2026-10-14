defmodule AlplusWeb.HomeLiveUiTest do
  @moduledoc "Focused layout contracts for the homepage's public evidence panels."

  use AlplusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Alplus.Content.Seeds
  alias Alplus.Measure.PublicCache

  setup do
    :ok = Seeds.run()
    previous = Application.get_env(:alplus, :homepage_preview_when_unconfigured)
    Application.put_env(:alplus, :homepage_preview_when_unconfigured, true)
    PublicCache.clear()

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:alplus, :homepage_preview_when_unconfigured)
      else
        Application.put_env(:alplus, :homepage_preview_when_unconfigured, previous)
      end

      PublicCache.clear()
    end)

    :ok
  end

  test "interactive evidence rows fill their layout cells", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/?metric=errors&monitor=0")

    assert_all_have_class(html, "#home-metrics button", 4, "w-full")
    assert_all_have_class(html, ~s(nav[aria-label="Published monitor"] button), 2, "w-full")
  end

  test "product evidence links to the relevant intent pages", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/?metric=errors&monitor=0")

    assert has_element?(view, ~s(#product a[href="/monitoring"]), "Explore monitoring")
    assert has_element?(view, ~s(#measure a[href="/analytics"]), "Explore analytics")
    assert has_element?(view, ~s(#observe img[src="/images/product/observe.webp"]))
    assert has_element?(view, ~s(#observe a[href="/error-tracking"]), "Explore error tracking")
  end

  test "landing actions expose hover and keyboard focus without changing selected controls", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, "/?metric=errors&monitor=0")

    assert_all_have_class(html, "#home-hero-cta", 1, "hover:bg-action-primary-hover")
    assert_all_have_class(html, "#home-hero-cta", 1, "hover:shadow-overlay")

    assert_all_have_class(
      html,
      "#home-final-cta a",
      1,
      "focus-visible:shadow-[var(--alp-focus-ring)]"
    )

    assert_all_have_class(
      html,
      ~s(#homepage button[aria-pressed]),
      12,
      "focus-visible:shadow-[var(--alp-focus-ring)]"
    )

    for {selector, count} <- [
          {~s(#console-preview-ranges button[aria-pressed="false"]), 2},
          {~s(#home-metrics button[aria-pressed="false"]), 3},
          {~s(nav[aria-label="Published monitor"] button[aria-pressed="false"]), 1},
          {~s(#home-measure-ranges button[aria-pressed="false"]), 2}
        ] do
      assert_all_have_class(html, selector, count, "hover:bg-interactive-tint")
    end

    assert_all_lack_class(
      html,
      ~s(#homepage button[aria-pressed="true"]),
      4,
      "hover:bg-interactive-tint"
    )
  end

  test "an empty publication surface says so instead of inventing evidence", %{conn: conn} do
    Application.put_env(:alplus, :homepage_preview_when_unconfigured, false)
    PublicCache.clear()

    {:ok, view, html} = live(conn, "/")

    # Nothing published is a fact the homepage states. It does not fill the
    # panel with invented entries or invented uptime squares, which a visitor
    # cannot tell from the designated project's real evidence.
    assert has_element?(view, "#home-status-preview", "No status page published yet")
    assert has_element?(view, "#console-preview-panel-changelog", "No updates are published yet")

    refute has_element?(view, ~s(#home-status-preview[data-state="example"]))
    refute has_element?(view, ~s(#console-preview-panel-changelog[data-state="example"]))
    refute html =~ "Example: Incident timeline improvements"
    refute html =~ "Example: New monitor coverage"

    for preview_value <- [
          "186ms",
          "99.98%",
          "2,410",
          "6,984",
          "v2.4.1",
          "Example project",
          "Example API",
          "Example monitor coverage"
        ] do
      refute html =~ preview_value
    end

    refute html =~ "PostDeploy project overview"
  end

  defp assert_all_have_class(html, selector, count, expected_class) do
    classes =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("class")

    assert length(classes) == count

    assert Enum.all?(classes, fn classes ->
             expected_class in String.split(classes)
           end)
  end

  defp assert_all_lack_class(html, selector, count, unexpected_class) do
    classes =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("class")

    assert length(classes) == count

    assert Enum.all?(classes, fn classes ->
             unexpected_class not in String.split(classes)
           end)
  end
end
