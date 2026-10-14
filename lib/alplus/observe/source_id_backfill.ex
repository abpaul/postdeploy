defmodule Alplus.Observe.SourceIdBackfill do
  @moduledoc """
  Pure source-lifecycle-window attribution (issue #46 follow-up): given the
  `:observe` Sources that ever existed for one `(org_id, project_id,
  environment)` slot, decides which Source owned a given historical row's
  timestamp.

  `Alplus.Sources.Source` carries no `revoked_at` timestamp — only `status`
  and `updated_at`, and `updated_at` also moves on a credential rotation, so
  it is not a reliable revocation marker (checked against the resource
  before writing this). Sources in one slot are instead ordered by
  `inserted_at` ascending; each Source's window runs from its own
  `inserted_at` up to the *next* Source's `inserted_at` in that slot
  (exclusive). The most recently created Source in a slot has an
  open-ended window. This reconstructs "which Source existed at this
  moment" without an extra column, and matches ADR 0001: a fresh Source is
  what replaces a revoked one in that slot.

  A timestamp older than every known Source in its slot, or a slot with no
  Sources at all, is genuinely ambiguous. It falls back to the slot's
  current active Source (or, absent one, its most recently created Source)
  and is reported as a fallback rather than silently treated as a window
  match — `Alplus.Observe.SourceIdBackfill.Runner` logs every fallback and
  every fully unattributed row.

  Kept dependency-free and DB-free on purpose so the attribution rule
  itself is unit-testable without touching Postgres.
  """

  @type source :: %{
          id: String.t(),
          org_id: String.t(),
          project_id: String.t(),
          environment: String.t(),
          status: :active | :revoked,
          inserted_at: DateTime.t()
        }

  @type slot :: {String.t(), String.t(), String.t()}

  @doc """
  Groups `sources` (already filtered to `type: :observe`) by
  `{org_id, project_id, environment}` and sorts each group by
  `inserted_at` ascending, ready for `attribute/2`.
  """
  @spec group_by_slot([source()]) :: %{slot() => [source()]}
  def group_by_slot(sources) do
    sources
    |> Enum.group_by(&{&1.org_id, &1.project_id, &1.environment})
    |> Map.new(fn {slot, group} -> {slot, Enum.sort(group, &lifecycle_order/2)} end)
  end

  # Sorted primarily by `inserted_at`; a tie (two Sources created in the
  # same instant, possible with clock coarseness or seeded test data) breaks
  # on `id` so attribution stays deterministic regardless of the order
  # `Alplus.Observe.SourceIdBackfill.Runner`'s query returns rows in (that
  # query carries no `ORDER BY`).
  defp lifecycle_order(a, b) do
    case DateTime.compare(a.inserted_at, b.inserted_at) do
      :lt -> true
      :gt -> false
      :eq -> a.id <= b.id
    end
  end

  @doc """
  Picks the Source id owning `timestamp` within one already
  `group_by_slot/1`-sorted slot's Source list.

    * `{:ok, source_id}` — `timestamp` fell inside that Source's window.
    * `{:fallback, source_id}` — no window matched; fell back to the active
      (or most recent) Source in the slot.
    * `:unattributed` — the slot has no Sources at all.
  """
  @spec attribute([source()], DateTime.t()) ::
          {:ok, String.t()} | {:fallback, String.t()} | :unattributed
  def attribute([], _timestamp), do: :unattributed

  def attribute(sorted_sources, timestamp) do
    case find_window(sorted_sources, timestamp) do
      {:ok, source} -> {:ok, source.id}
      :none -> {:fallback, fallback_source(sorted_sources).id}
    end
  end

  defp find_window(sorted_sources, timestamp) do
    sorted_sources
    |> Enum.zip(next_bounds(sorted_sources))
    |> Enum.find_value(:none, fn {source, window_end} ->
      in_window? =
        DateTime.compare(timestamp, source.inserted_at) != :lt and
          (window_end == :infinity or DateTime.compare(timestamp, window_end) == :lt)

      if in_window?, do: {:ok, source}
    end)
  end

  # Every Source's window ends where the next-created Source's window
  # begins; the last (most recent) Source's window never ends.
  defp next_bounds(sorted_sources) do
    sorted_sources
    |> Enum.map(& &1.inserted_at)
    |> Enum.drop(1)
    |> Kernel.++([:infinity])
  end

  defp fallback_source(sorted_sources) do
    Enum.find(sorted_sources, List.last(sorted_sources), &(&1.status == :active))
  end
end
