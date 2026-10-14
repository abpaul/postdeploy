defmodule Alplus.Observe.ReleaseHealth do
  @moduledoc """
  Event-derived release health for the Releases area: new-issue and
  resolved-issue counts per release, plus compare-to-previous.

  There is no separate ingest path for release health — every count is
  derived from existing `error_events`/`issues` rows tagged with the
  release's version, per ARCHITECTURE.md §8's fingerprint/release model.

  Scoped by `source_id`, not `environment` (issue #46 follow-up): a
  release belongs to one Source, and its health numbers must never blend
  in another Source's events, even one sharing the same environment name
  (a revoked predecessor, for example).
  """

  alias Alplus.Observe.Release
  alias Alplus.Repo

  require Ash.Query

  @max_evidence_issues 5
  @max_releases 100

  @type counts :: %{
          event_count: non_neg_integer(),
          new_issues: non_neg_integer(),
          resolved_issues: non_neg_integer()
        }

  @type artifact_summary :: %{
          count: non_neg_integer(),
          source_maps: non_neg_integer(),
          debug_files: non_neg_integer(),
          state: :none | :ready | :partial
        }

  @type summary :: %{
          counts: counts(),
          event_count: non_neg_integer(),
          new_issues: non_neg_integer(),
          resolved_issues: non_neg_integer(),
          artifacts: artifact_summary(),
          artifact_count: non_neg_integer(),
          source_map_count: non_neg_integer(),
          debug_file_count: non_neg_integer(),
          artifact_state: :none | :ready | :partial,
          symbolication_state: :unavailable | :partial | :ready,
          new_issue_ids: [String.t()],
          resolved_issue_ids: [String.t()],
          previous_release_id: String.t() | nil,
          previous_release_version: String.t() | nil,
          comparison: {:ok, map()} | {:error, :not_enough_history},
          comparison_state:
            :unavailable
            | :not_enough_history
            | :improved
            | :regressed
            | :unchanged
            | :mixed
        }

  @doc "The maximum number of release rows rendered by the Source detail page."
  @spec max_releases() :: pos_integer()
  def max_releases, do: @max_releases

  @doc """
  Returns health summaries for a bounded release list with fixed query count.

  Event counts, issue evidence, previous-release selection, and artifact
  availability come from one SQL read. Every join repeats the organization,
  project, Source, and membership predicates. The query never exposes storage
  keys or artifact payloads to callers.
  """
  @spec summaries(Alplus.Scope.t(), [Release.t()]) :: %{String.t() => summary()}
  def summaries(scope, releases) when is_list(releases) do
    releases =
      releases
      |> Enum.filter(&match?(%Release{id: id} when is_binary(id), &1))
      |> Enum.uniq_by(& &1.id)
      |> Enum.take(@max_releases)

    if releases == [] do
      %{}
    else
      summaries_query(scope, releases)
    end
  end

  # Phase A keeps release uniqueness on environment + version, but health
  # reads still pin `source_id`. A bare version-string match can pull in a
  # same-named release from a sibling Source. The NULL-aware predicate keeps
  # not-yet-backfilled releases from matching every row.
  @spec counts(Alplus.Scope.t(), Release.t()) :: counts()
  def counts(scope, %Release{} = release) do
    org_id = scope.org_id
    project_id = scope.project_id
    source_id = release.source_id
    version = release.version

    %{rows: [[event_count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM error_events
        WHERE org_id = $1 AND project_id = $2 AND release = $3
          AND (source_id = $4 OR ($4 IS NULL AND source_id IS NULL))
          AND EXISTS (
            SELECT 1 FROM memberships m
            WHERE m.org_id = $1 AND m.user_id = $5
          )
        """,
        [org_id, project_id, version, source_id, scope.user_id]
      )

    %{rows: [[new_issues]]} =
      Repo.query!(
        """
        SELECT count(*) FROM issues
        WHERE org_id = $1 AND project_id = $2 AND release_first_seen = $3
          AND (source_id = $4 OR ($4 IS NULL AND source_id IS NULL))
          AND EXISTS (
            SELECT 1 FROM memberships m
            WHERE m.org_id = $1 AND m.user_id = $5
          )
        """,
        [org_id, project_id, version, source_id, scope.user_id]
      )

    %{rows: [[resolved_issues]]} =
      Repo.query!(
        """
        SELECT count(*) FROM issues
        WHERE org_id = $1 AND project_id = $2 AND resolved_in_release_id = $3
          AND (source_id = $4 OR ($4 IS NULL AND source_id IS NULL))
          AND EXISTS (
            SELECT 1 FROM memberships m
            WHERE m.org_id = $1 AND m.user_id = $5
          )
        """,
        [org_id, project_id, release.id, source_id, scope.user_id]
      )

    %{event_count: event_count, new_issues: new_issues, resolved_issues: resolved_issues}
  end

  @doc "Counts releases without Source attribution in a tenant-scoped project."
  @spec unattributed_count(Alplus.Scope.t()) :: non_neg_integer()
  def unattributed_count(scope) do
    # `releases` has no Ash resource action that can express this aggregate
    # without loading every row. This direct read is bounded to one count and
    # repeats the same tenant and membership predicates as the resource policy.
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*)
        FROM releases r
        WHERE r.org_id = $1
          AND r.project_id = $2
          AND r.source_id IS NULL
          AND EXISTS (
            SELECT 1
            FROM memberships m
            WHERE m.org_id = $1 AND m.user_id = $3
          )
        """,
        [scope.org_id, scope.project_id, scope.user_id]
      )

    count
  end

  # "Previous" is the release with the immediately-earlier deploy time from
  # the same Source (ARCHITECTURE.md §8 release model; issue #46
  # follow-up: was project + environment, now project + source_id).
  @spec previous_release(Alplus.Scope.t(), Release.t()) :: Release.t() | nil
  def previous_release(scope, %Release{} = release) do
    query =
      Release
      |> Ash.Query.filter(
        org_id == ^scope.org_id and
          project_id == ^scope.project_id and
          (released_at < ^release.released_at or
             (released_at == ^release.released_at and id < ^release.id))
      )
      |> source_filter(release.source_id)
      |> Ash.Query.sort(released_at: :desc, id: :desc)
      |> Ash.Query.limit(1)

    case Ash.read(query, actor: scope) do
      {:ok, [previous]} -> previous
      _ -> nil
    end
  end

  defp source_filter(query, nil), do: Ash.Query.filter(query, is_nil(source_id))

  defp source_filter(query, source_id),
    do: Ash.Query.filter(query, source_id == ^source_id)

  # Both releases must have at least one event before a delta means anything
  # — never compute against zero (BUILD.md decision, issue #10).
  @spec compare(counts(), counts() | nil) ::
          {:ok, %{new_issues_delta: integer(), resolved_issues_delta: integer()}}
          | {:error, :not_enough_history}
  def compare(_current, nil), do: {:error, :not_enough_history}

  def compare(current, previous) do
    if current.event_count > 0 and previous.event_count > 0 do
      {:ok,
       %{
         new_issues_delta: current.new_issues - previous.new_issues,
         resolved_issues_delta: current.resolved_issues - previous.resolved_issues
       }}
    else
      {:error, :not_enough_history}
    end
  end

  defp summaries_query(scope, releases) do
    release_ids = Enum.map(releases, & &1.id)

    # This is one bounded aggregate for the entire release index. The CTEs
    # retain the immediate previous release even when it falls outside the
    # rendered page, so comparison state does not change at the page boundary.
    %{rows: rows} =
      Repo.query!(
        """
        WITH wanted AS (
          SELECT r.id,
                 r.source_id,
                 r.version,
                 previous.id AS previous_id,
                 previous.version AS previous_version
          FROM releases r
          LEFT JOIN LATERAL (
            SELECT p.id, p.version
            FROM releases p
            WHERE p.org_id = r.org_id
              AND p.project_id = r.project_id
              AND (p.released_at < r.released_at OR
                   (p.released_at = r.released_at AND p.id < r.id))
              AND p.source_id IS NOT DISTINCT FROM r.source_id
            ORDER BY p.released_at DESC, p.id DESC
            LIMIT 1
          ) previous ON TRUE
          WHERE r.org_id = $1
            AND r.project_id = $2
            AND r.id = ANY($3::text[])
            AND EXISTS (
              SELECT 1
              FROM memberships m
              WHERE m.org_id = $1 AND m.user_id = $4
            )
        ), all_releases AS (
          SELECT r.id, r.source_id, r.version
          FROM releases r
          JOIN (
            SELECT id FROM wanted
            UNION
            SELECT previous_id FROM wanted WHERE previous_id IS NOT NULL
          ) ids ON ids.id = r.id
          WHERE r.org_id = $1 AND r.project_id = $2
        ), event_counts AS (
          SELECT r.id, count(e.event_id)::bigint AS event_count
          FROM all_releases r
          LEFT JOIN error_events e
            ON e.org_id = $1
           AND e.project_id = $2
           AND e.release = r.version
           AND e.source_id IS NOT DISTINCT FROM r.source_id
          GROUP BY r.id
        ), new_issue_rows AS (
          SELECT r.id AS release_id,
                 i.id AS issue_id,
                 row_number() OVER (
                   PARTITION BY r.id
                   ORDER BY i.last_seen_at DESC, i.id DESC
                 ) AS rank
          FROM all_releases r
          JOIN issues i
            ON i.org_id = $1
           AND i.project_id = $2
           AND i.release_first_seen = r.version
           AND i.source_id IS NOT DISTINCT FROM r.source_id
        ), new_issue_counts AS (
          SELECT release_id,
                 count(*)::bigint AS new_issues,
                 array_agg(issue_id ORDER BY rank)
                   FILTER (WHERE rank <= $5) AS issue_ids
          FROM new_issue_rows
          GROUP BY release_id
        ), resolved_issue_rows AS (
          SELECT r.id AS release_id,
                 i.id AS issue_id,
                 row_number() OVER (
                   PARTITION BY r.id
                   ORDER BY i.last_seen_at DESC, i.id DESC
                 ) AS rank
          FROM all_releases r
          JOIN issues i
            ON i.org_id = $1
           AND i.project_id = $2
           AND i.resolved_in_release_id = r.id
           AND i.source_id IS NOT DISTINCT FROM r.source_id
        ), resolved_issue_counts AS (
          SELECT release_id,
                 count(*)::bigint AS resolved_issues,
                 array_agg(issue_id ORDER BY rank)
                   FILTER (WHERE rank <= $5) AS issue_ids
          FROM resolved_issue_rows
          GROUP BY release_id
        ), artifact_counts AS (
          SELECT a.release_id,
                 count(*)::bigint AS artifact_count,
                 count(*) FILTER (WHERE a.type = 'source_map')::bigint AS source_maps,
                 count(*) FILTER (WHERE a.type = 'debug_file')::bigint AS debug_files
          FROM release_artifacts a
          JOIN all_releases r ON r.id = a.release_id
          WHERE a.org_id = $1 AND a.project_id = $2
          GROUP BY a.release_id
        )
        SELECT w.id,
               w.previous_id,
               w.previous_version,
               COALESCE(ec.event_count, 0),
               COALESCE(nic.new_issues, 0),
               COALESCE(ric.resolved_issues, 0),
               COALESCE(pec.event_count, 0),
               COALESCE(pnic.new_issues, 0),
               COALESCE(pric.resolved_issues, 0),
               COALESCE(nic.issue_ids, ARRAY[]::text[]),
               COALESCE(ric.issue_ids, ARRAY[]::text[]),
               COALESCE(ac.artifact_count, 0),
               COALESCE(ac.source_maps, 0),
               COALESCE(ac.debug_files, 0)
        FROM wanted w
        LEFT JOIN event_counts ec ON ec.id = w.id
        LEFT JOIN new_issue_counts nic ON nic.release_id = w.id
        LEFT JOIN resolved_issue_counts ric ON ric.release_id = w.id
        LEFT JOIN event_counts pec ON pec.id = w.previous_id
        LEFT JOIN new_issue_counts pnic ON pnic.release_id = w.previous_id
        LEFT JOIN resolved_issue_counts pric ON pric.release_id = w.previous_id
        LEFT JOIN artifact_counts ac ON ac.release_id = w.id
        ORDER BY w.id
        """,
        [scope.org_id, scope.project_id, release_ids, scope.user_id, @max_evidence_issues]
      )

    Map.new(rows, &summary_row/1)
  end

  defp summary_row([
         release_id,
         previous_id,
         previous_version,
         event_count,
         new_issues,
         resolved_issues,
         previous_event_count,
         previous_new_issues,
         previous_resolved_issues,
         new_issue_ids,
         resolved_issue_ids,
         artifact_count,
         source_maps,
         debug_files
       ]) do
    current = %{
      event_count: integer_count(event_count),
      new_issues: integer_count(new_issues),
      resolved_issues: integer_count(resolved_issues)
    }

    previous =
      if is_nil(previous_id) do
        nil
      else
        %{
          event_count: integer_count(previous_event_count),
          new_issues: integer_count(previous_new_issues),
          resolved_issues: integer_count(previous_resolved_issues)
        }
      end

    artifacts = artifact_summary(artifact_count, source_maps, debug_files)

    {release_id,
     %{
       counts: current,
       # Keep the flat keys used by the existing Source detail template while
       # exposing the aggregate as a named value for new callers.
       event_count: current.event_count,
       new_issues: current.new_issues,
       resolved_issues: current.resolved_issues,
       artifacts: artifacts,
       artifact_count: artifacts.count,
       source_map_count: artifacts.source_maps,
       debug_file_count: artifacts.debug_files,
       artifact_state: artifacts.state,
       symbolication_state: symbolication_state(artifacts),
       new_issue_ids: normalize_ids(new_issue_ids),
       resolved_issue_ids: normalize_ids(resolved_issue_ids),
       previous_release_id: previous_id,
       previous_release_version: previous_version,
       comparison: compare(current, previous),
       comparison_state: comparison_state(previous_id, current, previous)
     }}
  end

  defp artifact_summary(artifact_count, source_maps, debug_files) do
    count = integer_count(artifact_count)
    source_maps = integer_count(source_maps)
    debug_files = integer_count(debug_files)

    state =
      cond do
        count == 0 -> :none
        source_maps > 0 -> :ready
        debug_files > 0 -> :partial
        true -> :none
      end

    %{count: count, source_maps: source_maps, debug_files: debug_files, state: state}
  end

  defp symbolication_state(%{state: :ready}), do: :ready
  defp symbolication_state(%{state: :partial}), do: :partial
  defp symbolication_state(_artifacts), do: :unavailable

  defp comparison_state(nil, _current, _previous), do: :unavailable

  defp comparison_state(_previous_id, current, previous) do
    if current.event_count > 0 and previous.event_count > 0 do
      new_delta = current.new_issues - previous.new_issues
      resolved_delta = current.resolved_issues - previous.resolved_issues

      cond do
        new_delta < 0 and resolved_delta >= 0 -> :improved
        new_delta > 0 and resolved_delta <= 0 -> :regressed
        new_delta == 0 and resolved_delta == 0 -> :unchanged
        true -> :mixed
      end
    else
      :not_enough_history
    end
  end

  defp normalize_ids(nil), do: []
  defp normalize_ids(ids) when is_list(ids), do: ids
  defp normalize_ids(_ids), do: []

  defp integer_count(value) when is_integer(value), do: value
  defp integer_count(value) when is_binary(value), do: String.to_integer(value)
  defp integer_count(_value), do: 0
end
