defmodule Alplus.Observe.SourceMapTest do
  use ExUnit.Case, async: true

  alias Alplus.Observe.SourceMap

  # Hand-computed rev-3 map. Generated line 1 carries three segments:
  #   "AAAAA" -> gen col 0,  src 0, orig line 0, col 0, name 0 (chargeOrder)
  #   "IACAC" -> gen col 4,  src 0, orig line 1, col 0, name 1 (boom)
  #   "SACA"  -> gen col 13, src 0, orig line 2, col 0, no name
  @map Jason.encode!(%{
         "version" => 3,
         "sources" => ["webpack://app/src/checkout.ts"],
         "names" => ["chargeOrder", "boom"],
         "mappings" => "AAAAA,IACAC,SACA",
         "sourcesContent" => [
           "function chargeOrder() {\n  boom();\n}\nexport { chargeOrder };\n"
         ]
       })

  test "parse + lookup resolve 1-based generated positions to original ones" do
    {:ok, parsed} = SourceMap.parse(@map)

    assert {:ok, position} = SourceMap.lookup(parsed, 1, 1)
    assert position.source == "webpack://app/src/checkout.ts"
    assert position.line == 1
    assert position.name == "chargeOrder"

    assert {:ok, position} = SourceMap.lookup(parsed, 1, 6)
    assert position.line == 2
    assert position.name == "boom"

    assert {:ok, position} = SourceMap.lookup(parsed, 1, 40)
    assert position.line == 3
    assert position.name == nil
  end

  test "lookup misses lines the map does not cover" do
    {:ok, parsed} = SourceMap.parse(@map)
    assert SourceMap.lookup(parsed, 2, 1) == :error
    assert SourceMap.lookup(parsed, 0, 0) == :error
  end

  test "source_context extracts surrounding lines from sourcesContent" do
    {:ok, parsed} = SourceMap.parse(@map)

    assert {:ok, context} =
             SourceMap.source_context(parsed, "webpack://app/src/checkout.ts", 2, 3)

    assert context.pre_context == ["function chargeOrder() {"]
    assert context.context_line == "  boom();"
    assert context.post_context == ["}", "export { chargeOrder };", ""]
  end

  test "source_context misses for an unknown source and a map with no content" do
    {:ok, parsed} = SourceMap.parse(@map)
    assert SourceMap.source_context(parsed, "unknown.ts", 1, 3) == :error

    bare =
      Jason.encode!(%{"version" => 3, "sources" => ["a.ts"], "mappings" => "AAAA"})

    {:ok, bare_parsed} = SourceMap.parse(bare)
    assert SourceMap.source_context(bare_parsed, "a.ts", 1, 3) == :error
  end

  test "source context preserves line boundaries and excludes text outside the requested window" do
    for separator <- ["\n", "\r\n"] do
      content = Enum.join(["first", "", "third", "fourth", "fifth", "last\r"], separator)

      {:ok, parsed} =
        SourceMap.parse(
          Jason.encode!(%{
            "version" => 3,
            "sources" => ["a.ts"],
            "mappings" => "AAAA",
            "sourcesContent" => [content]
          })
        )

      assert {:ok, %{pre_context: [], context_line: "first", post_context: [""]}} =
               SourceMap.source_context(parsed, "a.ts", 1, 1)

      assert {:ok, %{pre_context: [""], context_line: "third", post_context: ["fourth"]}} =
               SourceMap.source_context(parsed, "a.ts", 3, 1)

      assert {:ok, %{pre_context: ["fifth"], context_line: "last\r", post_context: []}} =
               SourceMap.source_context(parsed, "a.ts", 6, 1)

      assert {:ok, %{pre_context: [], context_line: "third", post_context: []}} =
               SourceMap.source_context(parsed, "a.ts", 3, 0)

      assert SourceMap.source_context(parsed, "a.ts", 7, 1) == :error
    end
  end

  test "source context preserves empty final lines and caps Unicode lines at 500 characters" do
    long_line = String.duplicate("e\u0301", 501)

    {:ok, parsed} =
      SourceMap.parse(
        Jason.encode!(%{
          "version" => 3,
          "sources" => ["a.ts"],
          "mappings" => "AAAA",
          "sourcesContent" => [long_line <> "\r\n"]
        })
      )

    capped = String.duplicate("e\u0301", 500)

    assert {:ok, %{pre_context: [], context_line: ^capped, post_context: [""]}} =
             SourceMap.source_context(parsed, "a.ts", 1, 3)

    assert {:ok, %{pre_context: [^capped], context_line: "", post_context: []}} =
             SourceMap.source_context(parsed, "a.ts", 2, 3)

    assert SourceMap.source_context(parsed, "a.ts", 3, 3) == :error
  end

  test "parse rejects non-v3 or malformed input" do
    assert SourceMap.parse("not json") == {:error, :invalid_source_map}
    assert SourceMap.parse(Jason.encode!(%{"version" => 2})) == {:error, :invalid_source_map}

    assert SourceMap.parse(Jason.encode!(%{"version" => 3, "mappings" => 7, "sources" => []})) ==
             {:error, :invalid_source_map}
  end

  test "decodes multi-line mappings and negative deltas" do
    # Two generated lines. Line 1: "AAAA" (gen col 0, a.ts) then "ICAA"
    # (gen col +4, src +1 -> b.ts). Line 2's "ADAA" carries src delta -1
    # (D = value 3 -> sign bit set, magnitude 1) back to a.ts.
    map =
      Jason.encode!(%{
        "version" => 3,
        "sources" => ["a.ts", "b.ts"],
        "names" => [],
        "mappings" => "AAAA,ICAA;ADAA"
      })

    {:ok, parsed} = SourceMap.parse(map)

    assert {:ok, %{source: "a.ts"}} = SourceMap.lookup(parsed, 1, 1)
    assert {:ok, %{source: "b.ts"}} = SourceMap.lookup(parsed, 1, 5)
    assert {:ok, %{source: "a.ts"}} = SourceMap.lookup(parsed, 2, 1)
  end
end
