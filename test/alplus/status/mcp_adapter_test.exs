defmodule Alplus.Status.McpAdapterTest do
  use ExUnit.Case, async: true

  alias Alplus.Status.McpAdapter

  test "catalog exposes the complete bounded Status lifecycle" do
    names = McpAdapter.tools() |> Enum.map(& &1.name)

    assert "status.get_health" in names
    assert "status.list_history" in names
    assert "status.create_service" in names
    assert "status.order_services" in names
    assert "status.save_incident_draft" in names
    assert "status.publish_incident_draft" in names
    assert "status.resolve_incident" in names
    assert "status.republish_announcement" in names
    assert "status.cancel_maintenance" in names
  end

  test "every Status mutation requires project scope and idempotency" do
    for tool <- McpAdapter.tools(), tool.requires_access == :read_write do
      assert tool.input_schema.required |> Enum.member?("project_handle")
      assert tool.input_schema.required |> Enum.member?("idempotency_key")
      assert tool.annotations.idempotentHint
      assert tool.annotations.openWorldHint
    end
  end

  test "retirement and cancellation are explicitly destructive" do
    tools = Map.new(McpAdapter.tools(), &{&1.name, &1})

    assert tools["status.retire_service"].annotations.destructiveHint
    assert tools["status.cancel_maintenance"].annotations.destructiveHint
    refute tools["status.publish_update"].annotations.destructiveHint
  end
end
