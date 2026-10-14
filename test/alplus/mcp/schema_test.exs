defmodule Alplus.Mcp.SchemaTest do
  use ExUnit.Case, async: true

  alias Alplus.Mcp.Schema

  describe "stringify/1" do
    test "converts an atom value to its string name" do
      assert Schema.stringify(:active) == "active"
    end

    test "leaves nil, true, and false untouched" do
      assert Schema.stringify(nil) == nil
      assert Schema.stringify(true) == true
      assert Schema.stringify(false) == false
    end

    test "converts atom values nested in maps and lists without disturbing other values" do
      input = %{
        status: :active,
        enabled: true,
        deleted_at: nil,
        tags: [:beta, "stable", :active],
        nested: %{kind: :pageview, count: 3}
      }

      assert Schema.stringify(input) == %{
               "status" => "active",
               "enabled" => true,
               "deleted_at" => nil,
               "tags" => ["beta", "stable", "active"],
               "nested" => %{"kind" => "pageview", "count" => 3}
             }
    end

    test "still stringifies map keys as before" do
      assert Schema.stringify(%{atom_key: 1}) == %{"atom_key" => 1}
    end

    test "a schema keyword like additionalProperties: false survives untouched" do
      schema = %{type: "object", additionalProperties: false}

      assert Schema.stringify(schema) == %{
               "type" => "object",
               "additionalProperties" => false
             }
    end
  end
end
