defmodule Alplus.Content.ArticleSeeds do
  @moduledoc "Imports scheduled blog Markdown from `priv/blog`."

  alias Alplus.Content

  @required ~w(title description slug published_at keywords cluster intent internal_links sources)
  @clusters ~w(uptime cron errors analytics observability)
  @intents ~w(informational commercial_investigation)

  def run(path \\ Application.app_dir(:alplus, "priv/blog")) do
    articles =
      path
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.sort()
      |> load_files()

    {:ok, :ok} =
      Ash.transact(Content.Article, fn ->
        Enum.each(articles, fn article ->
          {:ok, _} =
            Content.create_article(article,
              authorize?: false,
              upsert?: true,
              upsert_identity: :unique_slug,
              upsert_fields: [
                :title,
                :description,
                :published_at,
                :keywords,
                :cluster,
                :intent,
                :internal_links,
                :sources,
                :body_html
              ]
            )
        end)

        :ok
      end)

    :ok
  end

  def parse_file(path) do
    case :file.read_file(path) do
      {:ok, markdown} -> parse_markdown(markdown, Path.basename(path))
      {:error, reason} -> invalid!("#{Path.basename(path)}: cannot read source (#{reason})")
    end
  end

  def load_files([]), do: invalid!("no Markdown sources found")

  def load_files(paths) do
    parsed = Enum.map(paths, &parse_file/1)
    slugs = Enum.map(parsed, & &1.slug)

    if length(slugs) != length(Enum.uniq(slugs)), do: invalid!("duplicate article slug")

    Enum.sort_by(parsed, &DateTime.to_unix(&1.published_at, :microsecond))
  end

  defp parse_markdown(markdown, filename) do
    with {:ok, yaml, body} <- split_frontmatter(markdown),
         {:ok, metadata} <- read_yaml(yaml),
         :ok <- validate_keys(metadata),
         {:ok, attrs} <- validate_metadata(metadata, filename),
         {:ok, body_html} <- render_body(body) do
      Map.put(attrs, :body_html, body_html)
    else
      {:error, reason} -> invalid!("#{filename}: #{reason}")
    end
  end

  defp split_frontmatter(<<"---\n", rest::binary>>), do: split_end(rest)
  defp split_frontmatter(<<"---\r\n", rest::binary>>), do: split_end(rest)
  defp split_frontmatter(_), do: {:error, "missing YAML front matter"}

  defp split_end(rest) do
    case Regex.run(~r/\A(.*?)(?:\r?\n)(---|\.\.\.)(?:\r?\n|\z)(.*)\z/s, rest,
           capture: :all_but_first
         ) do
      [yaml, _delimiter, body] -> {:ok, yaml, body}
      _ -> {:error, "unterminated YAML front matter"}
    end
  end

  defp read_yaml(yaml) do
    case YamlElixir.read_from_string(yaml, maps_as_keywords: true) do
      {:ok, pairs} when is_list(pairs) ->
        if Enum.all?(pairs, &match?({_, _}, &1)), do: {:ok, pairs}, else: {:error, "invalid YAML"}

      _ ->
        {:error, "invalid YAML"}
    end
  rescue
    _ -> {:error, "invalid YAML"}
  end

  defp validate_keys(pairs) do
    keys = Enum.map(pairs, fn {key, _} -> to_string(key) end)

    cond do
      Enum.any?(keys, &(&1 not in @required)) -> {:error, "unknown YAML key"}
      length(keys) != length(Enum.uniq(keys)) -> {:error, "duplicate YAML key"}
      true -> :ok
    end
  end

  defp validate_metadata(pairs, filename) do
    metadata = Map.new(pairs, fn {key, value} -> {to_string(key), value} end)

    with :ok <- require_fields(metadata),
         {:ok, slug} <- slug(metadata["slug"]),
         {:ok, published_at} <- timestamp(metadata["published_at"]),
         :ok <- validate_enum(metadata["cluster"], @clusters, "cluster"),
         :ok <- validate_enum(metadata["intent"], @intents, "intent"),
         :ok <- validate_strings(metadata, filename),
         :ok <- validate_links(metadata["internal_links"]),
         :ok <- validate_urls(metadata["sources"]) do
      {:ok,
       %{
         slug: slug,
         title: metadata["title"],
         description: metadata["description"],
         published_at: published_at,
         keywords: metadata["keywords"],
         cluster: metadata["cluster"],
         intent: metadata["intent"],
         internal_links: metadata["internal_links"],
         sources: metadata["sources"]
       }}
    end
  end

  defp require_fields(metadata) do
    case Enum.find(@required, &(not Map.has_key?(metadata, &1))) do
      nil -> :ok
      key -> {:error, "missing #{key}"}
    end
  end

  defp slug(value) when is_binary(value) do
    value = String.trim(value)

    if String.length(value) <= 120 and Regex.match?(~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/, value),
      do: {:ok, value},
      else: {:error, "invalid slug"}
  end

  defp slug(_), do: {:error, "invalid slug"}

  defp timestamp(value) when is_binary(value) do
    if String.ends_with?(value, "Z") do
      case DateTime.from_iso8601(value) do
        {:ok, datetime, 0} -> {:ok, datetime}
        _ -> {:error, "invalid published_at"}
      end
    else
      {:error, "published_at must include UTC timezone Z"}
    end
  end

  defp timestamp(_), do: {:error, "published_at must be a quoted ISO8601 string"}

  defp validate_enum(value, allowed, _name) when is_binary(value) do
    if value in allowed, do: :ok, else: {:error, "invalid enum value"}
  end

  defp validate_enum(_, _, name), do: {:error, "invalid #{name}"}

  defp validate_strings(metadata, filename) do
    if Enum.all?(
         [{"title", 300}, {"description", 500}],
         fn {key, limit} ->
           is_binary(metadata[key]) and String.trim(metadata[key]) != "" and
             String.length(metadata[key]) <= limit
         end
       ) and
         is_list(metadata["keywords"]) and metadata["keywords"] != [] and
         Enum.all?(metadata["keywords"], &(is_binary(&1) and String.trim(&1) != "")) do
      :ok
    else
      {:error, "#{filename}: title, description, and keywords have invalid types"}
    end
  end

  defp validate_links(links) when is_list(links),
    do: if(Enum.all?(links, &valid_path?/1), do: :ok, else: {:error, "invalid internal_links"})

  defp validate_links(_), do: {:error, "internal_links must be a list"}

  defp valid_path?(path) when is_binary(path),
    do: Regex.match?(~r{\A/(?:[a-z0-9-]+/)*[a-z0-9-]*\z}, path)

  defp valid_path?(_), do: false

  defp validate_urls(urls) when is_list(urls) do
    if urls != [] and
         Enum.all?(urls, fn url ->
           is_binary(url) and
             match?(
               %URI{scheme: scheme, host: host}
               when scheme in ["http", "https"] and is_binary(host),
               URI.parse(url)
             )
         end), do: :ok, else: {:error, "sources must contain HTTP(S) URLs"}
  end

  defp validate_urls(_), do: {:error, "sources must be a list"}

  defp render_body(body) do
    case MDEx.to_html(body,
           extension: [table: true],
           sanitize: MDEx.Document.default_sanitize_options()
         ) do
      {:ok, html} ->
        if String.trim(body) != "" and
             html |> String.replace(~r/<!--.*?-->/s, "") |> String.trim() != "",
           do: {:ok, html},
           else: {:error, "empty Markdown body"}

      {:error, _} ->
        {:error, "invalid Markdown"}
    end
  end

  defp invalid!(message), do: raise(ArgumentError, "Article seed failed: #{message}")
end
