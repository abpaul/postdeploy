defmodule Alplus.PublicPages.McpAdapterTest do
  use ExUnit.Case, async: true

  alias Alplus.PublicPages.McpAdapter

  test "catalog exposes singleton identity reads and publication mutations" do
    names = McpAdapter.tools() |> Enum.map(& &1.name)

    assert names == Enum.sort(names)
    assert "public.get_identity" in names
    assert "public.list_aliases" in names
    assert "public.get_links" in names
    assert "public.update_identity" in names
    assert "public.publish" in names
    assert "public.unpublish" in names
  end

  test "identity mutations are customer-visible, idempotent, and project-scoped" do
    for tool <- McpAdapter.tools(), tool.requires_access == :read_write do
      assert tool.input_schema.required |> Enum.member?("project_handle")
      assert tool.input_schema.required |> Enum.member?("idempotency_key")
      assert tool.annotations.idempotentHint
      assert tool.annotations.openWorldHint
    end
  end

  test "identity output schema does not expose its private public token" do
    identity = Enum.find(McpAdapter.tools(), &(&1.name == "public.get_identity"))
    refute Map.has_key?(identity.output_schema.properties.identity.properties, :public_token)
    refute Map.has_key?(identity.output_schema.properties.identity.properties, :token)
  end
end
