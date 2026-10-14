defmodule Alplus.Observe.SessionHealth do
  @moduledoc """
  Crash-free sessions % for the Observe Releases area (issue #12),
  computed from `Alplus.Observe.SessionRollup`'s aggregate windows --
  never a raw per-session replay (ARCHITECTURE.md §13).

  Weighted by SESSIONS, not users (ARCHITECTURE.md decision #3: no user
  identity is collected, consistent with the cookieless/aggregate-only
  posture). Gated behind `@min_sessions`: below that count,
  `crash_free/3` returns `:not_enough_data` rather than a percentage that
  a tiny sample would make misleading (decision #4/user story 3) -- a
  95%-on-3-sessions "100%" is worse than no number at all.
  """

  alias Alplus.Observe.SessionRollup

  # Sentry's own release-health UI uses a similar order-of-magnitude
  # floor; picked here as a starting default, not derived from PostDeploy usage
  # data yet -- easy to move to plan config later if a founder wants it
  # tunable per plan.
  @min_sessions 25
  @max_releases 100

  def min_sessions, do: @min_sessions

  @type result ::
          {:ok,
           %{sessions: non_neg_integer(), crashed: non_neg_integer(), crash_free_pct: float()}}
          | :not_enough_data

  @type summary :: %{
          result: result(),
          state: :ready | :not_enough_data | :unattributed,
          sessions: non_neg_integer(),
          crashed: non_neg_integer(),
          minimum_sessions: pos_integer()
        }

  @doc """
  Sums every `SessionRollup` window for `release.version` + `source_id`
  within `scope` (org/project already pinned by the actor) and returns the
  crash-free percentage, or `:not_enough_data` below `min_sessions/0`.

  Scoped by `source_id`, not the bare `environment` string (issue #46
  follow-up finding 2): two Sources sharing one environment must never
  blend their crash-free numbers on one release.
  """
  @spec crash_free(Alplus.Scope.t(), String.t(), String.t() | nil) :: result()
  # A release with no source_id (its Source was hard-deleted, or it predates
  # the source_id backfill and stayed unattributed) has no source-scoped
  # rollups to sum -- never enough data, never a nil query argument.
  def crash_free(_scope, _release_version, nil), do: :not_enough_data

  def crash_free(scope, release_version, source_id) do
    query =
      SessionRollup
      |> Ash.Query.for_read(
        :list_for_release,
        %{project_id: scope.project_id, source_id: source_id, release: release_version},
        actor: scope
      )

    case Ash.read(query, actor: scope) do
      {:ok, rows} -> summarize(rows)
      {:error, _reason} -> :not_enough_data
    end
  end

  @doc """
  Returns session health for a bounded release list with one aggregate query.

  The join uses both the release version and Source id. It therefore keeps
  same-version releases isolated even when their environments match.
  """
  @spec summaries(Alplus.Scope.t(), [Alplus.Observe.Release.t()]) :: %{String.t() => summary()}
  def summaries(scope, releases) when is_list(releases) do
    releases =
      releases
      |> Enum.filter(&is_struct(&1, Alplus.Observe.Release))
      |> Enum.uniq_by(& &1.id)
      |> Enum.take(@max_releases)

    if releases == [] do
      %{}
    else
      release_ids = Enum.map(releases, & &1.id)

      %{rows: rows} =
        Alplus.Repo.query!(
          """
          SELECT r.id,
                 r.source_id,
                 COALESCE(SUM(sr.sessions_count), 0)::bigint,
                 COALESCE(SUM(sr.crashed_count), 0)::bigint
          FROM releases r
          LEFT JOIN observe_session_rollups sr
            ON sr.org_id = $1
           AND sr.project_id = $2
           AND sr.release = r.version
           AND sr.source_id IS NOT DISTINCT FROM r.source_id
          WHERE r.org_id = $1
            AND r.project_id = $2
            AND r.id = ANY($3::text[])
            AND EXISTS (
              SELECT 1
              FROM memberships m
              WHERE m.org_id = $1 AND m.user_id = $4
            )
          GROUP BY r.id, r.source_id
          """,
          [scope.org_id, scope.project_id, release_ids, scope.user_id]
        )

      Map.new(rows, fn [release_id, source_id, sessions, crashed] ->
        {release_id, build_summary(source_id, sessions, crashed)}
      end)
    end
  end

  defp summarize(rows) do
    sessions = Enum.sum_by(rows, & &1.sessions_count)
    crashed = Enum.sum_by(rows, & &1.crashed_count)

    if sessions < @min_sessions do
      :not_enough_data
    else
      pct = (sessions - crashed) / sessions * 100
      {:ok, %{sessions: sessions, crashed: crashed, crash_free_pct: pct}}
    end
  end

  defp build_summary(nil, _sessions, _crashed) do
    %{
      result: :not_enough_data,
      state: :unattributed,
      sessions: 0,
      crashed: 0,
      minimum_sessions: @min_sessions
    }
  end

  defp build_summary(source_id, sessions, crashed) when is_binary(source_id) do
    sessions = integer_count(sessions)
    crashed = integer_count(crashed)

    result =
      if sessions < @min_sessions do
        :not_enough_data
      else
        pct = (sessions - crashed) / sessions * 100
        {:ok, %{sessions: sessions, crashed: crashed, crash_free_pct: pct}}
      end

    %{
      result: result,
      state: if(sessions < @min_sessions, do: :not_enough_data, else: :ready),
      sessions: sessions,
      crashed: crashed,
      minimum_sessions: @min_sessions
    }
  end

  defp integer_count(value) when is_integer(value), do: value
  defp integer_count(value) when is_binary(value), do: String.to_integer(value)
  defp integer_count(_value), do: 0
end
