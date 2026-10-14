defmodule Alplus.Observe.SessionRollupWriter do
  @moduledoc """
  The optimized `POST /e/sessions` ingest writer (issue #12), mirroring
  `Alplus.Observe.EventWriter`/`Alplus.Measure.Rollups`: direct PostgreSQL
  upserts, not one Ash action per session, because ingest is a hot path
  (ARCHITECTURE.md §8).

  Never stores a raw per-session row. `session_id` is claimed in a
  short-lived dedup guard table (`observe_session_deduplications`, pruned
  after 24h by `Alplus.Observe.Retention.prune_session_dedup/1` -- the same
  window as every other idempotency key, ARCHITECTURE.md §13) purely to
  make a retried `POST /e/sessions` a no-op; once claimed, the session id
  itself is discarded and only the aggregate counters in
  `observe_session_rollups` (`Alplus.Observe.SessionRollup`) persist.

  Phase A of the Source-scoping rework (issue #46 follow-up finding 2, see
  `docs/observe-source-id-phase-b.md`): `source_id` is written as a data
  column, refreshed on every conflict, but the `ON CONFLICT` target stays
  `(org_id, project_id, environment, release, window_start)` for this
  deploy, for the same Kamal-cutover reason as `Alplus.Observe.EventWriter`.
  """

  alias Alplus.Repo

  @type session :: %{
          required(:session_id) => String.t(),
          required(:org_id) => String.t(),
          required(:project_id) => String.t(),
          required(:source_id) => String.t(),
          required(:environment) => String.t(),
          required(:status) => String.t(),
          required(:received_at) => DateTime.t(),
          optional(:release) => String.t() | nil
        }

  @spec record!(session()) :: :claimed | :duplicate
  def record!(session) do
    case claim_session_id(session) do
      :claimed ->
        upsert_rollup!(session)
        :claimed

      :duplicate ->
        :duplicate
    end
  end

  # Fully parameterized ($1, $2, ...); the SQL string itself is a fixed
  # compile-time literal with no interpolation.
  # sobelow_skip ["SQL.Query"]
  defp claim_session_id(session) do
    sql = """
    INSERT INTO observe_session_deduplications (session_id, org_id, project_id, received_at)
    VALUES ($1, $2, $3, $4)
    ON CONFLICT (session_id) DO NOTHING
    RETURNING session_id
    """

    case Repo.query!(sql, [
           session.session_id,
           session.org_id,
           session.project_id,
           session.received_at
         ]).rows do
      [[_session_id]] -> :claimed
      [] -> :duplicate
    end
  end

  # Fully parameterized ($1, $2, ...); the SQL string itself is a fixed
  # compile-time literal with no interpolation.
  # sobelow_skip ["SQL.Query"]
  defp upsert_rollup!(session) do
    window_start = DateTime.to_date(session.received_at)
    release = Map.get(session, :release) |> cap(256)
    {errored_delta, crashed_delta} = deltas(session.status)

    sql = """
    INSERT INTO observe_session_rollups (
      id, org_id, project_id, source_id, environment, release, window_start,
      sessions_count, errored_count, crashed_count, inserted_at, updated_at
    ) VALUES ($1, $2, $3, $4, $5, $6, $7, 1, $8, $9, $10, $10)
    ON CONFLICT (org_id, project_id, environment, release, window_start) DO UPDATE
    SET source_id = EXCLUDED.source_id,
        sessions_count = observe_session_rollups.sessions_count + 1,
        errored_count = observe_session_rollups.errored_count + EXCLUDED.errored_count,
        crashed_count = observe_session_rollups.crashed_count + EXCLUDED.crashed_count,
        updated_at = EXCLUDED.updated_at
    """

    Repo.query!(sql, [
      Alplus.Id.generate(:session_rollup),
      session.org_id,
      session.project_id,
      session.source_id,
      session.environment,
      release,
      window_start,
      errored_delta,
      crashed_delta,
      session.received_at
    ])

    :ok
  end

  # `"healthy"` contributes to neither delta; `"crashed"` counts ONLY as
  # crashed, never double-counted into `errored_count` too (ARCHITECTURE.md
  # decision #2 -- crash-free is `(sessions - crashed) / sessions`, so an
  # `errored` bucket that also included crashes would make that arithmetic
  # wrong).
  defp deltas("errored"), do: {1, 0}
  defp deltas("crashed"), do: {0, 1}
  defp deltas(_healthy), do: {0, 0}

  defp cap(nil, _limit), do: nil
  defp cap(value, limit), do: String.slice(value, 0, limit)
end
