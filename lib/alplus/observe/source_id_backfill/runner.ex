defmodule Alplus.Observe.SourceIdBackfill.Runner do
  @moduledoc """
  Batched, resumable orchestration for `Alplus.Observe.SourceIdBackfill`,
  driven by `mix observe.backfill_source_ids` (issue #46 follow-up).

  Reads `sources` and the target table directly with `Repo.query!`
  (`docs/DIRECT-ECTO-ESCAPE-HATCHES.md`: bounded maintenance work, no
  interactive browser actor). Each batch is a keyset scan (`id > $cursor`,
  never `OFFSET`) restricted to `source_id IS NULL`, so a row this run could
  not attribute (no Source ever existed for its slot) is visited once per
  run instead of looping forever, and a re-run after a crash or a manual
  stop safely revisits only the rows still NULL.

  Covers `issues`, `releases`, `error_events`, and (issue #46 follow-up
  finding 2) `observe_session_rollups`. `observe_session_rollups` has the
  same single-column text primary key shape as `issues`/`releases`, so it
  reuses `backfill_simple_table/3`; its timestamp is `window_start` (a UTC
  day, not a precise instant), so the whole aggregate row -- already a
  merge of every session in that day's window, from before `source_id`
  existed -- is attributed as one unit to whichever Source's lifecycle
  window contains that day. A day straddling a Source cutover is
  attributed to the Source active at day-start; this is a documented
  approximation, not a per-session split (no per-session row exists to
  split).
  """

  alias Alplus.Observe.SourceIdBackfill
  alias Alplus.Repo

  require Logger

  @batch_size 500

  @type table_result :: %{
          attributed: non_neg_integer(),
          fallback: non_neg_integer(),
          unattributed: non_neg_integer()
        }

  @doc """
  Backfills `issues`, `releases`, `error_events`, then
  `observe_session_rollups`. Returns one result map per table.
  """
  @spec run() :: %{
          issues: table_result(),
          releases: table_result(),
          error_events: table_result(),
          session_rollups: table_result()
        }
  def run do
    slots = load_slots()

    %{
      issues: backfill_simple_table("issues", "first_seen_at", slots),
      releases: backfill_simple_table("releases", "released_at", slots),
      error_events: backfill_error_events(slots),
      session_rollups: backfill_simple_table("observe_session_rollups", "window_start", slots)
    }
  end

  # ---- source lifecycle windows ---------------------------------------

  defp load_slots do
    %{rows: rows} =
      Repo.query!("""
      SELECT id, org_id, project_id, environment, status, inserted_at
      FROM sources
      WHERE type = 'observe'
      """)

    rows
    |> Enum.map(fn [id, org_id, project_id, environment, status, inserted_at] ->
      %{
        id: id,
        org_id: org_id,
        project_id: project_id,
        environment: environment,
        status: String.to_existing_atom(status),
        inserted_at: naive_to_utc(inserted_at)
      }
    end)
    |> SourceIdBackfill.group_by_slot()
  end

  defp naive_to_utc(%DateTime{} = dt), do: dt
  defp naive_to_utc(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")
  # `observe_session_rollups.window_start` is a `date` column (Postgrex
  # returns `~D[...]`), not a timestamp -- attributed at that day's start.
  defp naive_to_utc(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  # ---- issues / releases (single-column text primary key) -------------

  defp backfill_simple_table(table, timestamp_column, slots) do
    zero = %{attributed: 0, fallback: 0, unattributed: 0}
    simple_table_loop(table, timestamp_column, slots, "", zero)
  end

  # Callers supply table and column names from fixed module-owned lists.
  # sobelow_skip ["SQL.Query"]
  defp simple_table_loop(table, timestamp_column, slots, cursor, totals) do
    sql = """
    SELECT id, org_id, project_id, environment, #{timestamp_column}
    FROM #{table}
    WHERE source_id IS NULL AND id > $1
    ORDER BY id
    LIMIT $2
    """

    %{rows: rows} = Repo.query!(sql, [cursor, @batch_size])

    case rows do
      [] ->
        Logger.info("observe source_id backfill: #{table} done -- #{inspect(totals)}")
        totals

      rows ->
        batch_totals =
          Enum.reduce(rows, totals, fn [id, org_id, project_id, environment, ts], acc ->
            attribute_and_update_simple(
              table,
              id,
              org_id,
              project_id,
              environment,
              naive_to_utc(ts),
              slots,
              acc
            )
          end)

        Logger.info(
          "observe source_id backfill: #{table} batch of #{length(rows)} -- #{inspect(batch_totals)}"
        )

        next_cursor = rows |> List.last() |> List.first()
        simple_table_loop(table, timestamp_column, slots, next_cursor, batch_totals)
    end
  end

  defp attribute_and_update_simple(table, id, org_id, project_id, environment, ts, slots, totals) do
    slot_sources = Map.get(slots, {org_id, project_id, environment}, [])

    case SourceIdBackfill.attribute(slot_sources, ts) do
      {:ok, source_id} ->
        update_row(table, id, source_id)
        %{totals | attributed: totals.attributed + 1}

      {:fallback, source_id} ->
        Logger.warning(
          "observe source_id backfill: #{table}##{id} (#{org_id}/#{project_id}/#{environment}) " <>
            "had no matching Source window at #{DateTime.to_iso8601(ts)} -- fell back to #{source_id}"
        )

        update_row(table, id, source_id)
        %{totals | fallback: totals.fallback + 1}

      :unattributed ->
        Logger.warning(
          "observe source_id backfill: #{table}##{id} (#{org_id}/#{project_id}/#{environment}) " <>
            "has no Source at all for this slot -- left source_id NULL"
        )

        %{totals | unattributed: totals.unattributed + 1}
    end
  end

  # The table comes from the same fixed module-owned list.
  # sobelow_skip ["SQL.Query"]
  defp update_row(table, id, source_id) do
    sql = "UPDATE #{table} SET source_id = $1 WHERE id = $2 AND source_id IS NULL"
    Repo.query!(sql, [source_id, id])
  end

  # ---- error_events (composite primary key: received_at, event_id) ----

  defp backfill_error_events(slots) do
    zero = %{attributed: 0, fallback: 0, unattributed: 0}
    error_events_loop(slots, {~U[1970-01-01 00:00:00.000000Z], ""}, zero)
  end

  defp error_events_loop(slots, {cursor_received_at, cursor_event_id}, totals) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT event_id, received_at, org_id, project_id, environment
        FROM error_events
        WHERE source_id IS NULL
          AND (received_at, event_id) > ($1, $2)
        ORDER BY received_at, event_id
        LIMIT $3
        """,
        [cursor_received_at, cursor_event_id, @batch_size]
      )

    case rows do
      [] ->
        Logger.info("observe source_id backfill: error_events done -- #{inspect(totals)}")
        totals

      rows ->
        batch_totals =
          Enum.reduce(rows, totals, fn [event_id, received_at, org_id, project_id, environment],
                                       acc ->
            attribute_and_update_error_event(
              event_id,
              received_at,
              org_id,
              project_id,
              environment,
              slots,
              acc
            )
          end)

        Logger.info(
          "observe source_id backfill: error_events batch of #{length(rows)} -- #{inspect(batch_totals)}"
        )

        [event_id, received_at, _org_id, _project_id, _environment] = List.last(rows)
        error_events_loop(slots, {received_at, event_id}, batch_totals)
    end
  end

  defp attribute_and_update_error_event(
         event_id,
         received_at,
         org_id,
         project_id,
         environment,
         slots,
         totals
       ) do
    ts = naive_to_utc(received_at)
    slot_sources = Map.get(slots, {org_id, project_id, environment}, [])

    case SourceIdBackfill.attribute(slot_sources, ts) do
      {:ok, source_id} ->
        update_error_event(event_id, received_at, source_id)
        %{totals | attributed: totals.attributed + 1}

      {:fallback, source_id} ->
        Logger.warning(
          "observe source_id backfill: error_events##{event_id} (#{org_id}/#{project_id}/#{environment}) " <>
            "had no matching Source window at #{DateTime.to_iso8601(ts)} -- fell back to #{source_id}"
        )

        update_error_event(event_id, received_at, source_id)
        %{totals | fallback: totals.fallback + 1}

      :unattributed ->
        Logger.warning(
          "observe source_id backfill: error_events##{event_id} (#{org_id}/#{project_id}/#{environment}) " <>
            "has no Source at all for this slot -- left source_id NULL"
        )

        %{totals | unattributed: totals.unattributed + 1}
    end
  end

  defp update_error_event(event_id, received_at, source_id) do
    Repo.query!(
      "UPDATE error_events SET source_id = $1 WHERE event_id = $2 AND received_at = $3 AND source_id IS NULL",
      [source_id, event_id, received_at]
    )
  end
end
