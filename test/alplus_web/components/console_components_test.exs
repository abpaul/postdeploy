defmodule AlplusWeb.ConsoleComponentsTest do
  @moduledoc """
  Component tests for shared dashboard primitives.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AlplusWeb.ConsoleComponents

  test "dashboard_header/1 right-aligns a lone trailing action" do
    html =
      render_component(&ConsoleComponents.dashboard_header/1, %{
        trailing: [%{inner_block: fn _, _ -> "New thing" end}]
      })

    assert html =~ "justify-end"
    assert html =~ "New thing"
    refute html =~ "justify-between"
  end

  test "dashboard_header/1 justifies-between once a leading block is given" do
    html =
      render_component(&ConsoleComponents.dashboard_header/1, %{
        leading: [%{inner_block: fn _, _ -> "Breadcrumbs" end}],
        trailing: [%{inner_block: fn _, _ -> "New thing" end}]
      })

    assert html =~ "justify-between"
    assert html =~ "Breadcrumbs"
    assert html =~ "New thing"
  end

  test "status_dot/1 stays static while exposing an icon and text label" do
    up = render_component(&ConsoleComponents.status_dot/1, %{tone: "success", label: "Up"})
    assert up =~ "bg-status-live"
    refute up =~ "animate-pulse"
    assert up =~ ~s(aria-label="Up")
    assert up =~ "Up"
    assert up =~ "hero-check-circle"
    assert up =~ ~s(role="status")

    down = render_component(&ConsoleComponents.status_dot/1, %{tone: "error", label: "Down"})
    assert down =~ "bg-status-error"
    refute down =~ "animate-pulse"

    warning =
      render_component(&ConsoleComponents.status_dot/1, %{tone: "warning", label: "Degraded"})

    assert warning =~ "bg-status-late"
    refute warning =~ "motion-safe:animate-pulse"

    neutral = render_component(&ConsoleComponents.status_dot/1, %{label: "Paused"})
    assert neutral =~ "bg-status-neutral"
    refute neutral =~ "motion-safe:animate-pulse"
  end

  test "public status badge preserves public geometry and info colors" do
    html =
      render_component(&ConsoleComponents.status_badge/1, %{
        tone: "info",
        label: "Maintenance",
        size: :public
      })

    assert html =~ "gap-2"
    assert html =~ "px-3"
    assert html =~ "py-1"
    assert html =~ "text-[12.5px]"
    assert html =~ "font-semibold"
    assert html =~ "size-[7px]"
    assert html =~ "border-status-info-border"
    assert html =~ "bg-status-info-bg"
    assert html =~ "text-status-info-ink"
    assert html =~ "bg-status-info"
    refute html =~ "hero-information-circle"
  end

  test "summary_card/1 renders stat tiles, an extra slot, and an optional trend" do
    html =
      render_component(&ConsoleComponents.summary_card/1, %{
        id: "fleet-summary",
        headline: "All reporting resources are operational",
        subtitle: "Latest evidence just now",
        stats: [
          %{id: "stat-total", label: "Active", value: 3, class: "text-ink"},
          %{id: nil, label: "Down", value: 0, class: nil}
        ],
        extra: [%{inner_block: fn _, _ -> {:safe, ~s(<span id="stat-up">3</span>)} end}],
        trend: [%{inner_block: fn _, _ -> "distribution strip" end}]
      })

    assert html =~ ~s(id="fleet-summary")
    assert html =~ ~s(id="fleet-summary-title")
    # No eyebrow: the headline carries the band on its own.
    refute html =~ "uppercase"
    assert html =~ "All reporting resources are operational"
    assert html =~ ~s(id="stat-total")
    assert html =~ "Active"
    assert html =~ ~s(id="stat-up")
    assert html =~ "distribution strip"
  end

  test "summary_card/1 omits the trend block entirely when no slot is given" do
    html =
      render_component(&ConsoleComponents.summary_card/1, %{
        id: "fleet-summary-empty",
        eyebrow: "Fleet health",
        headline: "No evidence yet",
        stats: []
      })

    refute html =~ "distribution strip"
  end

  test "status badge, cards, empty state, and selects" do
    for tone <- ~w(success warning error info neutral) do
      html = render_component(&ConsoleComponents.status_badge/1, %{tone: tone, label: tone})
      assert html =~ tone
      assert html =~ ~s(role="status")
      assert html =~ "rounded-dot"
      assert html =~ "relative inline-flex"
    end

    html =
      render_component(&ConsoleComponents.stat_card/1, %{
        label: "Errors",
        value: 3,
        definition: "Open issues",
        hint: "24h",
        tone: "error"
      })

    assert html =~ "Errors"

    html =
      render_component(&ConsoleComponents.section_card/1, %{
        title: "Section",
        description: "Desc",
        inner_block: [%{inner_block: fn _, _ -> "body" end}]
      })

    assert html =~ "Section"

    html =
      render_component(&ConsoleComponents.empty_state/1, %{
        title: "Nothing here",
        description: "hint"
      })

    assert html =~ "Nothing here"

    html =
      render_component(&ConsoleComponents.permission_notice/1, %{
        message: "need admin"
      })

    assert html =~ "need admin"

    html =
      render_component(&ConsoleComponents.checklist_item/1, %{
        state: :done,
        title: "done item"
      })

    assert html =~ "done item"

    html =
      render_component(&ConsoleComponents.checklist_item/1, %{
        state: :current,
        title: "now",
        description: "do this",
        inner_block: [%{inner_block: fn _, _ -> "go" end}]
      })

    assert html =~ "now"

    html =
      render_component(&ConsoleComponents.checklist_item/1, %{
        state: :todo,
        title: "later"
      })

    assert html =~ "later"

    html =
      render_component(&ConsoleComponents.project_select/1, %{
        projects: [%{id: "p1", name: "One"}, %{id: "p2", name: "Two"}],
        project: %{id: "p1", name: "One"}
      })

    assert html =~ "One"

    html =
      render_component(&ConsoleComponents.environment_select/1, %{
        environment: "production",
        environments: ["production", "staging"]
      })

    assert html =~ "production"

    html =
      render_component(&ConsoleComponents.window_select/1, %{
        window: "24h",
        windows: ["24h", "7d"]
      })

    assert html =~ "24h"
  end

  test "definition list renders its row" do
    html =
      render_component(&ConsoleComponents.definition_list/1, %{
        row: [%{label: "URL", inner_block: fn _, _ -> "https://x" end}]
      })

    assert html =~ "URL"
  end

  describe "first_run_card/1" do
    defp first_run(overrides \\ %{}) do
      render_component(
        &ConsoleComponents.first_run_card/1,
        Map.merge(
          %{
            id: "fr",
            title: "No Measure evidence yet",
            description: "Pageviews appear here once a site reports.",
            state: :not_connected,
            task: "Inspect Measure traffic for this project.",
            action_href: "/dashboard/orgs/o/projects/p/connect"
          },
          overrides
        )
      )
    end

    test "leaves the connection state to the shell and names the next step" do
      not_connected = first_run()
      assert not_connected =~ "Open agent connection"

      awaiting = first_run(%{state: :awaiting_evidence})
      assert awaiting =~ "Check connection"

      # The top bar states the connection once per screen, so the card never
      # repeats it beside its own title.
      for html <- [not_connected, awaiting] do
        refute html =~ "Agent connection"
        refute html =~ "Agent connected"
        refute html =~ "Not connected"
      end
    end

    test "labels the copy control Copy task, product-wide" do
      html = first_run()

      assert html =~ ~s(id="fr-task")
      assert html =~ ~s(data-target="fr-task")
      assert html =~ "Copy task"
    end

    test "sets only the task string in mono, never the body or the link" do
      html = first_run()

      # The task box is the one mono region: it is a payload for a machine.
      assert html =~ ~r/id="fr-task"[^>]*class="[^"]*font-mono/

      # The sentence and the action are prose, so they carry the UI roles.
      assert html =~ ~r/class="[^"]*text-body[^"]*"[^>]*>\s*Pageviews appear here/
      assert html =~ ~r/id="fr-action"[^>]*class="[^"]*text-body/
      refute html =~ ~r/id="fr-action"[^>]*class="[^"]*(font-mono|text-data)/
    end

    test "is a left-aligned panel capped at the content column, not a dashed hero" do
      html = first_run()

      assert html =~ "max-w-prose"
      refute html =~ "border-dashed"
      refute html =~ "text-center"
      refute html =~ "flex-col items-center"
    end

    test "keeps no bordered box inside its own border" do
      html = first_run()

      # The prompt box is a fill, not a frame. A control (the badge, the copy
      # button) may carry its own edge; a container inside the card may not.
      assert html =~ ~r/id="fr-task"[^>]*class="[^"]*bg-surface-sunken/
      refute html =~ ~r/id="fr-task"[^>]*class="[^"]*\bborder\b/
    end
  end

  describe "console_page/1 opening" do
    test "draws exactly one visible h1 in the page role above the intro" do
      html =
        render_component(&ConsoleComponents.console_page/1, %{
          id: "page",
          title: [%{inner_block: fn _, _ -> "Measure" end}],
          intro: [%{inner_block: fn _, _ -> "Cookieless pageviews." end}],
          inner_block: [%{inner_block: fn _, _ -> "body" end}]
        })

      assert length(Regex.scan(~r/<h1\b/, html)) == 1
      assert html =~ ~r/<h1[^>]*class="[^"]*text-heading-01/
      assert html =~ "Measure"
      assert html =~ ~r/text-body-long text-text-secondary[^"]*"[^>]*>\s*Cookieless pageviews/
    end

    test "draws no heading block at all when a screen passes neither slot" do
      html =
        render_component(&ConsoleComponents.console_page/1, %{
          id: "page",
          inner_block: [%{inner_block: fn _, _ -> "body" end}]
        })

      refute html =~ "<h1"
    end
  end

  describe "empty_state/1 is the in-panel placeholder" do
    test "is a small dashed slot, not a page hero" do
      html =
        render_component(&ConsoleComponents.empty_state/1, %{
          title: "No checks yet",
          description: "Your agent can create the first one."
        })

      assert html =~ "border-dashed"
      assert html =~ "text-caption"
      # A hero would carry the section heading role and the panel surface.
      refute html =~ "text-heading-02"
      refute html =~ "bg-surface-raised"
    end
  end

  describe "data_panel/1 footer strip" do
    test "keeps an explanatory sentence inside the panel" do
      html =
        render_component(&ConsoleComponents.data_panel/1, %{
          id: "p",
          title: "Incidents",
          inner_block: [%{inner_block: fn _, _ -> "rows" end}],
          footer: [%{inner_block: fn _, _ -> "Publish it from the Public page." end}]
        })

      assert html =~ "Publish it from the Public page."
      assert html =~ "border-t border-border-subtle"
      assert html =~ "text-caption"
    end
  end
end
