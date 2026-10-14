defmodule AlplusWeb.CoreComponentsTest do
  use AlplusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias AlplusWeb.CoreComponents

  test "checkbox, header, list, and error translation" do
    html =
      render_component(&CoreComponents.input/1, %{
        type: "checkbox",
        id: "cb",
        name: "ok",
        value: "true",
        label: "Accept",
        errors: []
      })

    assert html =~ "Accept"

    html =
      render_component(&CoreComponents.header/1, %{
        inner_block: [%{inner_block: fn _, _ -> "Title" end}],
        subtitle: [%{inner_block: fn _, _ -> "Sub" end}],
        actions: [%{inner_block: fn _, _ -> "Act" end}]
      })

    assert html =~ "Title"

    html =
      render_component(&CoreComponents.list/1, %{
        item: [%{title: "One", inner_block: fn _, _ -> "a" end}]
      })

    assert html =~ "One"

    assert CoreComponents.translate_error({"should have %{count} item", [count: 1]}) =~ "1"

    assert CoreComponents.translate_errors([email: {"is invalid", []}], :email) == [
             "is invalid"
           ]
  end

  test "button variants use the shared target and semantic interaction tokens" do
    html =
      render_component(&CoreComponents.button/1, %{
        variant: "primary",
        inner_block: [%{inner_block: fn _, _ -> "Deploy" end}]
      })

    assert html =~ "h-control-md"
    refute html =~ "min-h-target-min"
    assert html =~ "rounded-control"
    assert html =~ "bg-action-primary"
    refute html =~ "shadow-block"
  end

  test "input associates errors with the control" do
    html =
      render_component(&CoreComponents.input/1, %{
        type: "email",
        id: "email",
        name: "email",
        value: "bad",
        errors: ["is invalid"]
      })

    assert html =~ ~s(aria-invalid="true")
    assert html =~ ~s(aria-describedby="email-error")
    assert html =~ ~s(id="email-error")
    assert html =~ "is invalid"
  end

  test "skeleton is static and modal exposes native dialog semantics" do
    skeleton = render_component(&CoreComponents.skeleton/1, %{rows: 2})
    assert skeleton =~ ~s(data-loading="static")
    refute skeleton =~ "animate-pulse"

    modal =
      render_component(&CoreComponents.modal/1, %{
        id: "details",
        title: "Details",
        description: "Deployment details",
        on_close: "close_details",
        inner_block: [%{inner_block: fn _, _ -> "Body" end}]
      })

    assert modal =~ ~s(<dialog)
    assert modal =~ ~s(phx-hook="AlplusWeb.CoreComponents.Modal")
    assert modal =~ ~s(data-close-event="close_details")
    assert modal =~ ~s(aria-labelledby="details-title")
    assert modal =~ ~s(aria-describedby="details-description")
  end

  test "flash dismisses through its named close control" do
    html =
      render_component(&CoreComponents.flash/1, %{
        kind: :error,
        flash: %{},
        inner_block: [%{inner_block: fn _, _ -> "The deploy failed" end}]
      })

    assert html =~ ~s(role="alert")
    assert html =~ "The deploy failed"
    assert html =~ "data-flash-close"
    assert html =~ "lv:clear-flash"
    assert html =~ "phx-click"
  end

  test "table row actions are semantic keyboard controls in the first cell" do
    html =
      render_component(&CoreComponents.table/1, %{
        id: "members",
        rows: [%{id: 1, name: "Ada", role: "Owner"}],
        row_id: &"member-#{&1.id}",
        row_click: fn _row -> "open_member" end,
        col: [
          %{label: "Name", inner_block: fn _, row -> row.name end},
          %{label: "Role", inner_block: fn _, row -> row.role end}
        ]
      })

    assert html =~ ~s(<button)
    assert html =~ ~s(phx-click="open_member")
    assert html =~ "Ada"
    assert html =~ "Owner"
    refute html =~ ~s(<td phx-click=)
  end

  test "table renders populated rows without an optional row click handler" do
    html =
      render_component(&CoreComponents.table/1, %{
        id: "observe-issues",
        rows: [%{id: "issue-1", title: "Database timeout"}],
        col: [%{label: "Issue", inner_block: fn _, row -> row.title end}]
      })

    assert html =~ "Database timeout"
    refute html =~ "phx-click"
  end

  test "copy button gives the hook-owned label a stable ignored subtree" do
    html = render_component(&CoreComponents.copy_button/1, %{target: "snippet"})

    assert html =~ ~s(phx-hook="AlplusWeb.CoreComponents.CopyButton")
    assert html =~ ~s(phx-update="ignore")
    assert html =~ ~s(id="copy-snippet-label")
    assert html =~ ~s(data-copy-label)
    assert html =~ ~s(data-copy-fallback="textarea")
  end

  test "shared navigation, feedback, layout, and data primitives expose their contracts" do
    tabs =
      render_component(&CoreComponents.tabs/1, %{
        id: "sections",
        active: "overview",
        on_change: "select_tab",
        tabs: [
          %{id: "overview", label: "Overview"},
          %{id: "incidents", label: "Incidents", disabled: true}
        ]
      })

    assert tabs =~ ~s(role="tablist")
    assert tabs =~ ~s(role="tab")
    assert tabs =~ ~s(aria-selected="true")
    assert tabs =~ ~s(id="sections-tab-overview")
    assert tabs =~ ~s(aria-controls="sections-panel-overview")
    assert tabs =~ ~s(phx-value-tab="overview")
    assert tabs =~ ~s(phx-hook="AlplusWeb.CoreComponents.Tabs")
    assert tabs =~ "ArrowLeft"
    assert tabs =~ "ArrowRight"
    assert tabs =~ "Home"
    assert tabs =~ "End"

    tabs_source =
      File.read!(Path.expand("../../../lib/alplus_web/components/core_components.ex", __DIR__))

    refute tabs_source =~ "tab.setAttribute"
    refute tabs_source =~ "removeAttribute"
    assert tabs_source =~ "tabs[next].focus()"
    assert tabs_source =~ "tabs[next].click()"
    assert tabs =~ "disabled"

    default_tabs =
      render_component(&CoreComponents.tabs/1, %{
        id: "default-sections",
        on_change: "select_tab",
        tabs: [
          %{id: "unavailable", label: "Unavailable", disabled: true},
          %{id: "ready", label: "Ready"}
        ]
      })

    assert default_tabs =~ ~s(phx-value-tab="ready")
    assert default_tabs =~ ~s(aria-selected="true")
    assert default_tabs =~ ~s(id="default-sections-tab-ready")

    pagination =
      render_component(&CoreComponents.pagination/1, %{
        id: "pages",
        current_page: 2,
        total_pages: 3,
        on_change: "change_page"
      })

    assert pagination =~ ~s(role="navigation")
    assert pagination =~ ~s(aria-current="page")
    assert pagination =~ ~s(phx-value-page="2")
    assert pagination =~ ~s(id="pages-previous")
    assert pagination =~ ~s(id="pages-next")

    assert_raise ArgumentError, ~r/exactly one/, fn ->
      render_component(&CoreComponents.pagination/1, %{
        id: "inert-pages",
        current_page: 1,
        total_pages: 2
      })
    end

    assert_raise ArgumentError, ~r/exactly one/, fn ->
      render_component(&CoreComponents.pagination/1, %{
        id: "ambiguous-pages",
        current_page: 1,
        total_pages: 2,
        path: "/entries",
        on_change: "change_page"
      })
    end

    for {kind, icon} <- [
          {"live", "hero-check-circle"},
          {"late", "hero-exclamation-triangle"},
          {"error", "hero-x-circle"},
          {"paused", "hero-pause-circle"},
          {"neutral", "hero-information-circle"}
        ] do
      alert =
        render_component(&CoreComponents.alert/1, %{
          id: "alert-#{kind}",
          kind: kind,
          message: "State: #{kind}"
        })

      assert alert =~ icon
      assert alert =~ "State: #{kind}"
      assert alert =~ ~s(data-kind="#{kind}")
    end

    article =
      render_component(&CoreComponents.article_layout/1, %{
        id: "article",
        title: "Release notes",
        description: "What changed",
        inner_block: [%{inner_block: fn _, _ -> "Body" end}],
        aside: [%{inner_block: fn _, _ -> "Contents" end}]
      })

    assert article =~ ~s(<article)
    assert article =~ "Release notes"
    assert article =~ "Body"
    assert article =~ "Contents"

    code =
      render_component(&CoreComponents.code_panel/1, %{
        id: "example-code",
        filename: "deploy.ex",
        language: "elixir",
        code: "IO.puts(\"ready\")"
      })

    assert code =~ "deploy.ex"
    assert code =~ "elixir"
    assert code =~ ~s(id="example-code-code")
    assert code =~ ~s(data-target="example-code-code")

    metric =
      render_component(&CoreComponents.metric_row/1, %{
        id: "latency",
        label: "Latency",
        value: 240,
        unit: "ms",
        tone: "late"
      })

    assert metric =~ "Latency"
    assert metric =~ "240"
    assert metric =~ "ms"
    assert metric =~ ~s(<dt)
    assert metric =~ ~s(<dd)

    index =
      render_component(&CoreComponents.index_row/1, %{
        id: "entry-1",
        title: "First entry",
        description: "A short description",
        meta: "Updated today",
        href: "/entries/1",
        selected: true
      })

    assert index =~ ~s(aria-current="true")
    assert index =~ ~s(href="/entries/1")
    assert index =~ "First entry"
    assert index =~ "Updated today"

    loading_index =
      render_component(&CoreComponents.index_row/1, %{
        id: "entry-loading",
        title: "Loading entry",
        state: :loading,
        href: "/entries/loading"
      })

    assert loading_index =~ ~s(data-state="loading")
    assert loading_index =~ ~s(data-loading="static")
    refute loading_index =~ ~s(href="/entries/loading")

    empty_index =
      render_component(&CoreComponents.index_row/1, %{
        id: "entry-empty",
        title: "Empty entry",
        state: :empty,
        message: "No entries have been published.",
        action: [%{inner_block: fn _, _ -> "Create entry" end}]
      })

    assert empty_index =~ ~s(role="status")
    assert empty_index =~ "No entries have been published."
    assert empty_index =~ "Create entry"

    error_index =
      render_component(&CoreComponents.index_row/1, %{
        id: "entry-error",
        title: "Error entry",
        state: :error,
        message: "Entries could not load."
      })

    assert error_index =~ ~s(role="alert")
    assert error_index =~ "Entries could not load."

    disabled_index =
      render_component(&CoreComponents.index_row/1, %{
        id: "entry-disabled",
        title: "Disabled entry",
        state: :disabled,
        message: "Available on a paid plan.",
        href: "/entries/disabled"
      })

    assert disabled_index =~ ~s(aria-disabled="true")
    assert disabled_index =~ "Available on a paid plan."
    refute disabled_index =~ ~s(href="/entries/disabled")

    assert_raise ArgumentError, ~r/requires a non-empty message/, fn ->
      render_component(&CoreComponents.index_row/1, %{
        id: "entry-missing",
        title: "Missing",
        state: :empty
      })
    end
  end
end
