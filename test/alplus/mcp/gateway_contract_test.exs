defmodule Alplus.Mcp.GatewayContractTest do
  use ExUnit.Case, async: true

  alias Alplus.Mcp.{Catalog, Discovery, Gateway, Principal, Tool}

  @principal %Principal{
    grant_id: "grant_test",
    org_id: "organization_test",
    project_id: "project_test",
    user_id: "user_test",
    role: nil,
    correlation_id: "request_test",
    scopes: ["monitor:read", "monitor:write"],
    access: :read_write,
    source: :oauth
  }

  test "gateway exposes exactly eight stable tools" do
    assert Enum.map(Gateway.wire_tools(@principal), & &1.name) == Gateway.names()
    assert length(Gateway.wire_tools(@principal)) == 8
    refute Enum.any?(Gateway.wire_tools(@principal), &String.contains?(&1.name, "monitor."))
  end

  test "every internal operation has one canonical safety class" do
    classes = Tool.safety_classes()

    assert Catalog.all() != []

    for tool <- Catalog.all() do
      assert Tool.safety_class(tool) in classes
      assert is_binary(tool.audit_subject)
      assert is_list(tool.prerequisites)
      assert is_list(tool.examples)
    end
  end

  test "search ranks deterministically and includes the exact schema for a unique result" do
    assert {:ok, %{"matches" => matches, "next_cursor" => nil}} =
             Discovery.search(@principal, %{
               "intent" => "monitor list",
               "area" => "monitor",
               "limit" => 10
             })

    assert matches != []
    assert hd(matches)["action"] == "monitor.list"
    assert is_map(hd(matches)["input_schema"])

    assert {:ok, %{"matches" => repeated}} =
             Discovery.search(@principal, %{
               "intent" => "monitor list",
               "area" => "monitor",
               "limit" => 10
             })

    assert Enum.map(matches, & &1["action"]) == Enum.map(repeated, & &1["action"])
  end

  test "actions.read rejects an action from another safety class before dispatch" do
    assert {:error, %{code: :safety_class_mismatch, details: details}} =
             Gateway.call(
               "actions.read",
               %{
                 "action" => "monitor.create",
                 "arguments" => %{},
                 "_meta" => %{"trace" => "hidden"}
               },
               @principal
             )

    assert details.expected == :read
    assert details.actual == :write
  end

  test "actions.destroy rejects a missing write scope before creating a confirmation" do
    principal = %{@principal | scopes: ["monitor:read"], access: :read}

    assert {:error, %{code: :insufficient_scope}} =
             Gateway.call(
               "actions.destroy",
               %{
                 "action" => "monitor.delete",
                 "arguments" => %{"monitor_handle" => "mon_test"},
                 "idempotency_key" => "destroy-test"
               },
               principal
             )
  end

  describe "the publish safety class" do
    # Alplus.Mcp.Tool's moduledoc defines :publish as an action that creates,
    # rotates, or exposes something usable from outside the organization. Both
    # areas issue an ingest credential the same way, so both classify the same.
    @publish [
      "observe.create_source",
      "observe.rotate_source",
      "measure.create_source",
      "measure.rotate_source",
      "measure.create_dashboard_share",
      "measure.update_dashboard_share",
      "measure.rotate_dashboard_share"
    ]

    # These change state that never leaves the organization.
    @write [
      "observe.capture_error",
      "observe.resolve_issue",
      "observe.assign_issue",
      "observe.create_issue_comment",
      "measure.create_goal",
      "measure.update_goal",
      "measure.create_event_definition"
    ]

    test "a credential-issuing or externally reachable action is :publish" do
      for name <- @publish do
        assert Tool.safety_class(catalog_tool(name)) == :publish,
               "expected #{name} to be :publish"
      end
    end

    test "an action whose effect stays inside the organization is :write" do
      for name <- @write do
        assert Tool.safety_class(catalog_tool(name)) == :write,
               "expected #{name} to be :write"
      end
    end

    test "both create_source actions share one class" do
      assert Tool.safety_class(catalog_tool("observe.create_source")) ==
               Tool.safety_class(catalog_tool("measure.create_source"))
    end

    test "actions.write rejects a publish action before dispatch" do
      for name <- ["observe.create_source", "measure.create_source"] do
        assert {:error, %{code: :safety_class_mismatch, details: details}} =
                 Gateway.call(
                   "actions.write",
                   %{"action" => name, "arguments" => %{}, "idempotency_key" => "k"},
                   @principal
                 )

        assert details.expected == :write
        assert details.actual == :publish
      end
    end

    test "actions.publish rejects a write action before dispatch" do
      assert {:error, %{code: :safety_class_mismatch, details: details}} =
               Gateway.call(
                 "actions.publish",
                 %{
                   "action" => "observe.resolve_issue",
                   "arguments" => %{},
                   "idempotency_key" => "k"
                 },
                 @principal
               )

      assert details.expected == :publish
      assert details.actual == :write
    end
  end

  defp catalog_tool(name) do
    Enum.find(Catalog.all(), &(&1.name == name)) || flunk("no catalog tool named #{name}")
  end
end
