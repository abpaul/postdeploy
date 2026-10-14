defmodule Alplus.Observe.ReleaseListing do
  @moduledoc """
  Per-Source Release reads for the Source page and the issue page.

  Scoped by `source_id`, not `environment` (issue #46 follow-up): a
  release belongs to one Source, so a sibling Source sharing an
  environment name never appears in this list.

  `Alplus.Observe.ReleaseHealth` derives health numbers for the rows this
  module returns; the two stay separate so a list read never pays for a
  health aggregate it does not need.
  """

  alias Alplus.Observe.Release

  require Ash.Query

  @doc """
  Returns one bounded page of releases plus whether more rows follow.

  `page_size` bounds the page; the query reads one extra row to answer
  "is there another page" without a second count.
  """
  @spec page(Alplus.Scope.t(), String.t(), pos_integer(), pos_integer()) ::
          {[Release.t()], boolean()}
  def page(scope, source_id, page, page_size)
      when is_binary(source_id) and is_integer(page) and page > 0 and is_integer(page_size) and
             page_size > 0 do
    releases =
      scope
      |> query(source_id)
      |> Ash.Query.sort(released_at: :desc, id: :desc)
      |> Ash.Query.limit(page_size + 1)
      |> Ash.Query.offset((page - 1) * page_size)
      |> Ash.read!(actor: scope)

    {Enum.take(releases, page_size), length(releases) > page_size}
  end

  @doc "Counts every release under one Source."
  @spec count(Alplus.Scope.t(), String.t()) :: non_neg_integer()
  def count(scope, source_id) when is_binary(source_id) do
    Ash.count!(query(scope, source_id), actor: scope)
  end

  @doc "Returns the most recent release under one Source, or `nil`."
  @spec latest(Alplus.Scope.t(), String.t() | nil) :: Release.t() | nil
  def latest(_scope, nil), do: nil

  def latest(scope, source_id) when is_binary(source_id) do
    scope
    |> query(source_id)
    |> Ash.Query.sort(released_at: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: scope)
    |> List.first()
  end

  defp query(scope, source_id) do
    Release
    |> Ash.Query.for_read(:list_for_project, %{project_id: scope.project_id}, actor: scope)
    |> Ash.Query.filter(source_id == ^source_id)
  end
end
