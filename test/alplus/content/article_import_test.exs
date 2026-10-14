defmodule Alplus.Content.ArticleImportTest do
  use Alplus.DataCase, async: false

  alias Alplus.Content

  test "imports all sources idempotently and applies schedule edits by stable slug" do
    path =
      Path.join(System.tmp_dir!(), "postdeploy-blog-import-#{System.unique_integer([:positive])}")

    File.mkdir!(path)
    source = Path.join(path, "fixture-import.md")

    on_exit(fn ->
      File.rm(source)
      File.rmdir(path)
    end)

    write_article(source, "2099-10-12T09:00:00Z", "Initial description")
    assert :ok = Content.ArticleSeeds.run(path)
    {:ok, [first]} = Ash.read(Content.Article, authorize?: false)
    assert first.slug == "fixture-import"
    assert {:error, _} = Content.get_article_by_slug("fixture-import")

    write_article(source, "2000-10-12T09:00:00Z", "Revised description")
    assert :ok = Content.ArticleSeeds.run(path)
    {:ok, [second]} = Ash.read(Content.Article, authorize?: false)
    assert second.id == first.id
    assert second.description == "Revised description"
    assert {:ok, %{id: id}} = Content.get_article_by_slug("fixture-import")
    assert id == first.id

    assert :ok = Content.ArticleSeeds.run(path)
    {:ok, [third]} = Ash.read(Content.Article, authorize?: false)
    assert third.id == first.id
  end

  test "invalid source prevents publication of other sources in the same import" do
    path =
      Path.join(
        System.tmp_dir!(),
        "postdeploy-blog-invalid-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(path)
    valid = Path.join(path, "valid.md")
    invalid = Path.join(path, "invalid.md")

    on_exit(fn ->
      File.rm(valid)
      File.rm(invalid)
      File.rmdir(path)
    end)

    write_article(valid, "2000-10-12T09:00:00Z", "Valid")
    write_article(invalid, "2000-10-12T09:00:00Z", "Invalid")

    File.write!(
      invalid,
      File.read!(invalid) |> String.replace("Import fixture", String.duplicate("x", 301))
    )

    assert_raise ArgumentError, fn -> Content.ArticleSeeds.run(path) end
    assert {:ok, []} = Content.list_articles()
  end

  test "a database write failure rolls back earlier articles in the batch" do
    path =
      Path.join(
        System.tmp_dir!(),
        "postdeploy-blog-rollback-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(path)
    first = Path.join(path, "a.md")
    second = Path.join(path, "b.md")

    on_exit(fn ->
      File.rm(first)
      File.rm(second)
      File.rmdir(path)
    end)

    write_article(first, "2000-10-12T09:00:00Z", "Accepted")
    write_article(second, "2000-10-12T09:00:00Z", "Rejected")
    File.write!(second, String.replace(File.read!(second), "fixture-import", "fixture-rejected"))

    Alplus.Repo.query!("""
    CREATE FUNCTION pg_temp.reject_blog_fixture() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.slug = 'fixture-rejected' THEN
        RAISE EXCEPTION 'fixture write failure';
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    Alplus.Repo.query!("""
    CREATE TRIGGER reject_blog_fixture BEFORE INSERT ON content_articles
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_blog_fixture()
    """)

    assert_raise MatchError, fn -> Content.ArticleSeeds.run(path) end
    assert {:ok, []} = Ash.read(Content.Article, authorize?: false)
  end

  test "missing publication timestamps and empty target keywords cannot create articles" do
    attrs = %{
      slug: "invalid",
      title: "Title",
      description: "Description",
      keywords: ["target"],
      cluster: "uptime",
      intent: "informational",
      internal_links: [],
      sources: ["https://example.com"],
      body_html: "<p>Body</p>"
    }

    assert {:error, _} = Content.create_article(attrs, authorize?: false)

    assert {:error, _} =
             Content.create_article(
               Map.merge(attrs, %{published_at: ~U[2000-01-01 00:00:00Z], keywords: []}),
               authorize?: false
             )
  end

  defp write_article(path, at, description) do
    File.write!(path, """
    ---
    title: "Import fixture"
    description: "#{description}"
    slug: "fixture-import"
    published_at: "#{at}"
    keywords: ["fixture import"]
    cluster: "uptime"
    intent: "informational"
    internal_links: []
    sources: ["https://example.com/source"]
    ---
    ## Useful result

    A test fixture.
    """)
  end
end
