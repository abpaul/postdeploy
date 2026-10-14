defmodule Alplus.Seo.Inventory do
  @moduledoc """
  The registry of public content: what each page is for, which cluster it
  belongs to, and the one query it is meant to win (PRD §39, §40).

  Read from `Alplus.Content.Page`, `.Guide` and `.Comparison` rows rather
  than kept as a separate literal: `cluster`, `intent` and `primary_query`
  are `allow_nil? false` attributes on each resource, so a row cannot be
  created without declaring them and there is nothing left to drift. This
  module is now a runtime read, not a compile-time list — every function
  here queries the database, so a caller cannot use it inside a module
  attribute (`@foo Inventory.entries()`); call it inside a function body.

  `Alplus.Seo.Audit` still fails when two published pages claim the same
  primary query (`no_query_cannibalisation`); it no longer needs
  `pages_are_in_the_inventory` or `inventory_has_no_dead_entries`, because
  `allow_nil? false` gives the same guarantee at insert time instead of at
  audit time.

  ## Why the primary query matters

  Two pages targeting one query is cannibalisation: they split the signals
  that would have ranked either of them, and Google picks whichever it
  prefers, which is often the weaker one. The fix is to merge them or to
  re-point one at a genuinely different question, and neither happens if
  nobody notices. Declaring the query makes the collision detectable.

  ## Intent

  One of `:informational`, `:commercial_investigation`, `:transactional` or
  `:navigational`, following the standard taxonomy. Intent drives what the
  page owes the reader: a `:transactional` page must make the action
  obvious, while an `:informational` one must answer the question well
  enough to be worth citing even by someone who never buys.

  ## Non-content entries

  `/changelog` is a stable public page with no `Content` row behind it (the
  first-party changelog is data-backed per organisation, not a seeded
  marketing page — see `Alplus.Seo.Audit.public_paths/0`), so it cannot be
  derived and stays declared here.
  """

  alias Alplus.Content

  @type intent ::
          :informational | :commercial_investigation | :transactional | :navigational

  @type entry :: %{
          path: String.t(),
          type: :page | :guide | :comparison | :article,
          cluster: String.t(),
          intent: intent(),
          primary_query: String.t()
        }

  # See the "Non-content entries" moduledoc section above.
  @non_content_entries [
    %{
      path: "/blog",
      type: :page,
      cluster: "observability",
      intent: :navigational,
      primary_query: "postdeploy blog"
    },
    %{
      path: "/changelog",
      type: :page,
      cluster: "changelog",
      intent: :navigational,
      primary_query: "postdeploy changelog"
    },
    %{
      path: "/tools/website-health-check",
      type: :page,
      cluster: "uptime",
      intent: :informational,
      primary_query: "website health check"
    }
  ]

  @doc "Every inventory entry: every published content row, plus the few pages that have none."
  @spec entries() :: [entry()]
  def entries do
    {:ok, pages} = Content.list_pages()
    {:ok, guides} = Content.list_guides()
    {:ok, comparisons} = Content.list_comparisons()
    {:ok, articles} = Content.list_articles()

    Enum.map(pages, &to_entry(&1, :page)) ++
      Enum.map(guides, &to_entry(&1, :guide)) ++
      Enum.map(comparisons, &to_entry(&1, :comparison)) ++
      Enum.map(articles, fn article ->
        %{
          path: "/blog/#{article.slug}",
          type: :article,
          cluster: article.cluster,
          intent: String.to_existing_atom(article.intent),
          primary_query: hd(article.keywords)
        }
      end) ++ @non_content_entries
  end

  defp to_entry(row, type) do
    %{
      path: row.path,
      type: type,
      cluster: row.cluster,
      intent: String.to_existing_atom(row.intent),
      primary_query: row.primary_query
    }
  end

  @doc "Every path in the inventory."
  @spec paths() :: [String.t()]
  def paths, do: Enum.map(entries(), & &1.path)

  @doc "The entry for a path, or `nil`."
  @spec entry(String.t()) :: entry() | nil
  def entry(path), do: Enum.find(entries(), &(&1.path == path))

  @doc "Entries grouped by cluster, the unit growth reporting counts in."
  @spec by_cluster() :: %{String.t() => [entry()]}
  def by_cluster, do: Enum.group_by(entries(), & &1.cluster)

  @doc """
  Primary queries claimed by more than one page, with the paths claiming
  them. An empty map is the healthy state.
  """
  @spec cannibalised_queries() :: %{String.t() => [String.t()]}
  def cannibalised_queries do
    entries()
    |> Enum.group_by(&normalize_query(&1.primary_query), & &1.path)
    |> Enum.filter(fn {_query, paths} -> length(paths) > 1 end)
    |> Map.new()
  end

  # Case and surrounding whitespace never distinguish two search queries,
  # so they must not hide a collision either.
  defp normalize_query(query), do: query |> String.trim() |> String.downcase()
end
