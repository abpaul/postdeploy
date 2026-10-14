defmodule Alplus.Changelog.FrontMatterTest do
  use ExUnit.Case, async: true

  alias Alplus.Changelog.FrontMatter

  test "parses a scalar title and body" do
    assert {:ok, %{title: "Ship", body: "\nBody\n"}} =
             FrontMatter.parse("---\ntitle: Ship\n---\n\nBody\n")
  end

  test "rejects malformed YAML" do
    assert {:error, :malformed_yaml} = FrontMatter.parse("---\ntitle: [\n---\nBody")
  end

  test "rejects unknown keys" do
    assert {:error, :unknown_key} = FrontMatter.parse("---\ntitle: Ship\nauthor: Paul\n---\nBody")
  end

  test "rejects duplicate keys" do
    assert {:error, :duplicate_key} = FrontMatter.parse("---\ntitle: One\ntitle: Two\n---\nBody")
  end

  test "rejects nested values" do
    assert {:error, :nested_value} =
             FrontMatter.parse("---\ntitle:\n  nested: true\n---\nBody")
  end

  test "rejects missing title" do
    assert {:error, :missing_title} = FrontMatter.parse("---\n---\nBody")
  end

  test "rejects an empty or non-scalar title" do
    assert {:error, :invalid_title} = FrontMatter.parse("---\ntitle: \"\"\n---\nBody")
    assert {:error, :nested_value} = FrontMatter.parse("---\ntitle: [one, two]\n---\nBody")
  end

  test "rejects raw HTML in the body" do
    assert {:error, :raw_html_forbidden} =
             FrontMatter.parse("---\ntitle: Ship\n---\n<div>unsafe</div>")
  end

  test "parses the optional public metadata contract" do
    markdown = """
    ---
    title: Ship
    summary: Safer public releases
    area: Observe
    version: 2.4.0
    media: https://cdn.example.test/releases/ship.png
    media_alt: Ship dashboard
    media_caption: The release dashboard
    ---
    Body
    """

    assert {:ok,
            %{
              title: "Ship",
              body: "Body\n",
              summary: "Safer public releases",
              area: "observe",
              version: "2.4.0",
              media_url: "https://cdn.example.test/releases/ship.png",
              media_alt: "Ship dashboard",
              media_caption: "The release dashboard"
            }} = FrontMatter.parse_public(markdown)
  end

  test "requires safe media metadata" do
    assert {:error, :invalid_media_alt} =
             FrontMatter.parse_public("""
             ---
             title: Unsafe image
             media_url: https://cdn.example.test/image.png
             ---
             Body
             """)

    assert {:error, :invalid_media_url} =
             FrontMatter.parse_public("""
             ---
             title: Unsafe image
             media_url: javascript:alert(1)
             media_alt: Image
             ---
             Body
             """)

    assert {:error, :duplicate_key} =
             FrontMatter.parse_public("""
             ---
             title: Duplicate image
             media: https://cdn.example.test/one.png
             media_url: https://cdn.example.test/two.png
             media_alt: Image
             ---
             Body
             """)
  end
end
