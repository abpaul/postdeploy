defmodule AlplusWeb.Observe.EvidenceTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Alplus.Observe.Occurrence
  alias AlplusWeb.Observe.Evidence

  defp occurrence(overrides) do
    struct!(
      %Occurrence{
        event_id: "err_1",
        received_at: ~U[2026-08-12 09:00:00Z],
        sdk_name: "alplus-elixir",
        sdk_version: "0.1.0"
      },
      overrides
    )
  end

  describe "occurrence_columns/1" do
    test "a single occurrence shows only Received" do
      assert Evidence.occurrence_columns([occurrence([])]) == [:received]
    end

    test "identical SDK/user/release across rows stay hidden" do
      rows = [
        occurrence(event_id: "a", user_id: "u1", release: "1.0.0"),
        occurrence(event_id: "b", user_id: "u1", release: "1.0.0")
      ]

      assert Evidence.occurrence_columns(rows) == [:received]
    end

    test "a field that changes is included" do
      rows = [
        occurrence(event_id: "a", sdk_name: "alplus-ruby", sdk_version: "0.3.0"),
        occurrence(event_id: "b", sdk_name: "alplus-elixir", sdk_version: "0.1.0")
      ]

      assert Evidence.occurrence_columns(rows) == [:received, :sdk]
    end
  end

  describe "unique_cause_frames/2" do
    test "drops a cause stack that names no new site" do
      frames = [%{file: "app/a.rb", function: "run"}]
      assert Evidence.unique_cause_frames(%{frames: frames}, frames) == []
    end

    test "keeps a cause stack with a unique file and function" do
      parent = [%{file: "app/wrap.rb", function: "call"}]
      cause = [%{file: "app/root.rb", function: "parse"}]
      assert Evidence.unique_cause_frames(%{frames: cause}, parent) == cause
    end
  end

  describe "member_display_name/1" do
    test "prefers a set name" do
      assert Evidence.member_display_name(%{name: "Ada", email: "ada@example.com"}) == "Ada"
    end

    test "humanizes the email local-part when name is missing" do
      assert Evidence.member_display_name(%{name: nil, email: "owner.person+tag@example.com"}) ==
               "Owner Person"
    end
  end

  describe "request_context/1 and extra_context/1" do
    test "lifts contexts.request and drops it from extra" do
      occurrence =
        occurrence(
          context: %{
            "request" => %{"method" => "POST", "path" => "/orders"},
            "extra" => %{"cart_id" => "c1"}
          }
        )

      assert Evidence.request_context(occurrence)["path"] == "/orders"
      extra = Evidence.extra_context(occurrence, %{context_summary: nil})
      refute Map.has_key?(extra, "request")
      assert extra["extra"]["cart_id"] == "c1"
    end
  end

  describe "highlight_items/1" do
    test "lists named client contexts and leaves environment and release off" do
      occurrence =
        occurrence(
          release: "1.2.3",
          context: %{"os" => %{"name" => "macOS"}, "runtime" => %{"name" => "BEAM"}}
        )

      items = Evidence.highlight_items(occurrence)
      refute Enum.any?(items, &(&1.label == "Environment"))
      refute Enum.any?(items, &(&1.label == "Release"))
      assert Enum.any?(items, &(&1.label == "OS" and &1.value == "macOS"))
      assert Enum.any?(items, &(&1.label == "Runtime" and &1.value == "BEAM"))
    end
  end

  describe "request_detail_items/1" do
    test "flattens headers, query, and params and skips the lead-line keys" do
      items =
        Evidence.request_detail_items(%{
          "method" => "POST",
          "path" => "/orders",
          "host" => "app.test",
          "headers" => %{"user-agent" => "alplus-elixir/0.1", "referer" => "/cart"},
          "query" => %{"page" => "2"},
          "params" => %{"id" => "9"}
        })

      labels = Enum.map(items, & &1.label)
      refute "method" in labels
      refute "path" in labels
      refute "host" in labels
      assert %{label: "user-agent", value: "alplus-elixir/0.1"} in items
      assert %{label: "Query page", value: "2"} in items
      assert %{label: "Param id", value: "9"} in items
    end

    test "returns no rows when only method and path are present" do
      assert Evidence.request_detail_items(%{"method" => "GET", "path" => "/"}) == []
    end
  end

  describe "visible_frames/2 and raw_stack/2" do
    test "reverses and filters to in-app frames" do
      frames = [
        %{function: "Lib.call", in_app: false},
        %{function: "App.run", in_app: true}
      ]

      assert [%{function: "App.run"}] =
               Evidence.visible_frames(frames, in_app_only: true)

      assert [%{function: "App.run"}, %{function: "Lib.call"}] =
               Evidence.visible_frames(frames, order: :newest_first)

      raw = Evidence.raw_stack(frames, in_app_only: true, type: "RuntimeError", value: "boom")
      assert raw =~ "RuntimeError: boom"
      assert raw =~ "App.run"
      refute raw =~ "Lib.call"
    end

    test "in-app only keeps the stack when no frame is marked in-app" do
      frames = [%{function: "Lib.call", file: "/node_modules/x.js", in_app: false}]

      assert Evidence.visible_frames(frames, in_app_only: true) == frames

      assert Evidence.stack_summary(frames, in_app_only: true) =~
               "No frames marked in-app"
    end

    test "stack_summary counts hidden library frames" do
      frames = [
        %{function: "Lib.call", in_app: false},
        %{function: "App.run", in_app: true}
      ]

      assert Evidence.stack_summary(frames, in_app_only: true, order: :newest_first, view: :raw) =~
               "Showing 1 in-app of 2"
    end
  end

  describe "adjacent_event_ids/2" do
    test "older is the next row, newer is the previous row" do
      rows = [occurrence(event_id: "new"), occurrence(event_id: "old")]
      assert {"old", nil} = Evidence.adjacent_event_ids(rows, "new")
      assert {nil, "new"} = Evidence.adjacent_event_ids(rows, "old")
    end
  end

  describe "relative_time/2" do
    test "renders a day-scale offset" do
      now = ~U[2026-08-17 12:00:00Z]
      then = ~U[2026-08-15 12:00:00Z]
      assert Evidence.relative_time(then, now) == "2 days ago"
    end
  end

  describe "copy_for_ai/2" do
    test "includes the title and stack" do
      issue = %{
        title: "TypeError: boom",
        culprit: "run/1",
        environment: "awards",
        status: :open,
        event_count: 1
      }

      text = Evidence.copy_for_ai(issue, occurrence(frames: [%{function: "run", file: "a.ex"}]))
      assert text =~ "TypeError: boom"
      assert text =~ "run @ a.ex"
    end
  end

  describe "before_crumbs/1 and after_crumbs/1" do
    test "splits on the after_error marker" do
      occurrence =
        occurrence(
          breadcrumbs: [
            %{category: "log", message: "start"},
            %{category: "log", message: "retry", data: %{"after_error" => true}}
          ]
        )

      assert [%{message: "start"}] = Evidence.before_crumbs(occurrence)
      assert [%{message: "retry"}] = Evidence.after_crumbs(occurrence)
    end

    test "non-occurrence values are empty" do
      assert Evidence.before_crumbs(:nope) == []
      assert Evidence.after_crumbs(:nope) == []
    end
  end

  describe "stack_frames/1" do
    test "uses inverse semantic tokens for code frames and the selected source line" do
      html =
        render_component(&Evidence.stack_frames/1,
          frames: [
            %{
              file: "a.ex",
              function: "run/1",
              lineno: 2,
              in_app: true,
              pre_context: ["a"],
              context_line: "b",
              post_context: ["c"]
            }
          ]
        )

      assert html =~ "bg-surface-inverse"
      assert html =~ "border-border-subtle"
      assert html =~ "text-text-inverse-muted"
      assert html =~ "bg-surface-inverse-raised"
      assert html =~ "text-text-inverse"
      refute html =~ "border-white/5"
      refute html =~ "bg-white/10"
      refute html =~ "#A9B49B"
      refute html =~ "#E8ECDF"
    end
  end

  test "request details, time buckets, labels, and raw helpers" do
    assert Evidence.request_detail_items(nil) == []

    items =
      Evidence.request_detail_items(%{
        "query_string" => "a=1",
        "headers" => %{"x" => 1, "ok" => true, "no" => false, "list" => [1, 2], "map" => %{a: 1}}
      })

    assert Enum.any?(items, &(&1.label == "Query"))
    assert Evidence.member_display_name(nil) == "Unnamed"
    assert Evidence.assignee_label([], "missing") == "Unassigned"
    assert Evidence.assignee_label([%{id: "u1", label: "Ada"}], "u1") == "Ada"

    now = ~U[2026-08-17 12:00:00Z]
    assert Evidence.relative_time(~N[2026-08-17 11:59:30], now) == "just now"
    assert Evidence.relative_time(~U[2026-08-17 11:30:00Z], now) =~ "minutes"
    assert Evidence.relative_time(~U[2026-08-17 08:00:00Z], now) =~ "hours"
    assert Evidence.relative_time(~U[2025-01-01 00:00:00Z], now) =~ "months"

    assert {nil, nil} = Evidence.adjacent_event_ids([occurrence([])], "missing")

    raw = Evidence.raw_stack([%{file: "a.ex", lineno: 3, colno: 2}], type: "Error")
    assert raw =~ "Error"
    assert raw =~ "a.ex:3:2"

    assert is_binary(Evidence.raw_event(occurrence([])))

    html =
      render_component(&Evidence.stack_frames/1,
        frames: [
          %{
            file: "a.ex",
            function: "run/1",
            lineno: 2,
            in_app: true,
            pre_context: ["a"],
            context_line: "b",
            post_context: ["c"]
          }
        ]
      )

    assert html =~ "run/1"

    html =
      render_component(&Evidence.breadcrumb_line/1,
        crumb: %{
          message: "m",
          category: "log",
          timestamp: DateTime.add(now, -90, :second),
          data: %{"k" => "v", "n" => 1}
        },
        occurred_at: now
      )

    assert html =~ "m"
  end
end
