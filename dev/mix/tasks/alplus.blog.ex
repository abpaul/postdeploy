defmodule Mix.Tasks.Alplus.Blog do
  @shortdoc "Validate scheduled blog sources and print the editorial calendar"

  use Mix.Task

  alias Alplus.Content.ArticleSeeds

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)
    {:ok, _} = Application.ensure_all_started(:mdex)

    paths =
      Application.app_dir(:alplus, "priv/blog")
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.sort()

    articles = ArticleSeeds.load_files(paths)

    if "--calendar" in args do
      Enum.each(articles, fn article ->
        IO.puts(
          "#{DateTime.to_iso8601(article.published_at)}\t#{article.title}\t/blog/#{article.slug}\t#{article.intent}\t#{Enum.join(article.keywords, ", ")}\t#{Enum.join(article.internal_links, ", ")}"
        )
      end)
    else
      Mix.shell().info("Validated #{length(paths)} blog source files.")
    end
  end
end
