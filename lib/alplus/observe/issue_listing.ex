defmodule Alplus.Observe.IssueListing do
  @moduledoc """
  Project-wide Observe issue reads for the index table.

  Filters stay on `list_for_project` so org and project scope never leave
  the Ash action. Merged children stay hidden. A hard limit keeps the
  table query bounded.

  `list/2` and `count/2` are the external seam. Both take the same option
  set, so a page and its total always share one filter definition. `:tag`
  needs `:source_id`; a tag lives on events, and events belong to a Source.
  """

  alias Alplus.Observe.{Issue, IssueEvidence}

  require Ash.Query

  @limit 200
  @page_size 50
  @max_search_bytes 200

  @spec limit() :: pos_integer()
  def limit, do: @limit

  @doc "Maximum rows shown in one Source page."
  def page_size, do: @page_size

  @spec list(map(), keyword()) :: [Issue.t()]
  def list(scope, opts \\ []) do
    status = Keyword.get(opts, :status, "open")
    level = Keyword.get(opts, :level, "all")
    environment = Keyword.get(opts, :environment, "all")
    search = Keyword.get(opts, :search, "")
    source_id = Keyword.get(opts, :source_id)
    tag = Keyword.get(opts, :tag, "")

    page_size = normalize_page_size(Keyword.get(opts, :page_size, @limit))
    page = normalize_page(Keyword.get(opts, :page, 1))

    query =
      query(scope,
        status: status,
        level: level,
        environment: environment,
        search: search,
        source_id: source_id,
        tag: tag
      )

    query
    |> Ash.Query.sort(last_seen_at: :desc)
    |> Ash.Query.limit(page_size)
    |> Ash.Query.offset((page - 1) * page_size)
    |> Ash.Query.load(:source)
    |> Ash.read!(actor: scope)
  end

  @doc "Counts matching rows without the page limit."
  @spec count(map(), keyword()) :: non_neg_integer()
  def count(scope, opts \\ []) do
    opts = Keyword.put_new(opts, :source_id, nil)
    Ash.count!(query(scope, opts), actor: scope)
  end

  @doc "Returns the number of pages for a bounded Source issue list."
  def total_pages(total, page_size \\ @page_size)
      when is_integer(total) and total >= 0 and is_integer(page_size) and page_size > 0 do
    max(div(total + page_size - 1, page_size), 1)
  end

  defp query(scope, opts) do
    status = Keyword.get(opts, :status, "open")
    level = Keyword.get(opts, :level, "all")
    environment = Keyword.get(opts, :environment, "all")
    search = Keyword.get(opts, :search, "")
    source_id = Keyword.get(opts, :source_id)
    tag = Keyword.get(opts, :tag, "")

    Issue
    |> Ash.Query.for_read(:list_for_project, %{project_id: scope.project_id}, actor: scope)
    |> Ash.Query.filter(is_nil(merged_into_issue_id))
    |> filter_by_source(source_id)
    |> filter_by_status(status)
    |> filter_by_level(level)
    |> filter_by_environment(environment)
    |> filter_by_search(search)
    |> filter_by_tag(scope, source_id, tag)
  end

  defp normalize_page(page) when is_integer(page) and page > 0, do: page
  defp normalize_page(_page), do: 1

  defp normalize_page_size(page_size) when is_integer(page_size) and page_size > 0,
    do: min(page_size, @limit)

  defp normalize_page_size(_page_size), do: @limit

  defp filter_by_source(query, nil), do: query
  defp filter_by_source(query, source_id), do: Ash.Query.filter(query, source_id == ^source_id)

  defp filter_by_status(query, "open"), do: Ash.Query.filter(query, status == :open)
  defp filter_by_status(query, "resolved"), do: Ash.Query.filter(query, status == :resolved)
  defp filter_by_status(query, "ignored"), do: Ash.Query.filter(query, status == :ignored)
  defp filter_by_status(query, _all), do: query

  defp filter_by_level(query, level) when level in ~w(fatal error warning info),
    do: Ash.Query.filter(query, level == ^level)

  defp filter_by_level(query, _all), do: query

  defp filter_by_environment(query, "all"), do: query
  defp filter_by_environment(query, ""), do: query

  defp filter_by_environment(query, environment) when is_binary(environment) do
    Ash.Query.filter(query, environment == ^environment)
  end

  defp filter_by_search(query, ""), do: query

  defp filter_by_search(query, search) do
    pattern = "%" <> String.replace(search, ~r/([\\%_])/, "\\\\\\1") <> "%"

    Ash.Query.filter(
      query,
      fragment("? ILIKE ?", title, ^pattern) or fragment("? ILIKE ?", culprit, ^pattern)
    )
  end

  defp filter_by_tag(query, _scope, _source_id, tag) when tag in [nil, ""], do: query
  defp filter_by_tag(query, _scope, nil, _tag), do: query

  defp filter_by_tag(query, scope, source_id, tag) do
    case String.split(tag, ":", parts: 2) do
      [key, value] ->
        ids = IssueEvidence.issue_ids_for_tag(scope, source_id, key, value)
        Ash.Query.filter(query, id in ^ids)

      _ ->
        query
    end
  end

  @spec clamp_search(term()) :: String.t()
  def clamp_search(q) when is_binary(q), do: String.slice(String.trim(q), 0, @max_search_bytes)
  def clamp_search(_q), do: ""
end
