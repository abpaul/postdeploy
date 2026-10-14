defmodule Alplus.Observe.DedupSourceIdBackfill do
  @moduledoc """
  Batched, resumable backfill of `error_event_deduplications.source_id`
  (issue #46 follow-up, see the "Observe error-event dedup" section in
  `docs/observe-source-id-phase-b.md`), driven by
  `mix observe.backfill_dedup_source_ids`.

  Unlike `Alplus.Observe.SourceIdBackfill` (which reconstructs the owning
  Source from a row's own timestamp and each Source's lifecycle window,
  because `issues`/`releases`/`error_events` predate `source_id`), this
  table can be backfilled exactly: `error_events` already carries the
  correct `source_id` for the same `event_id`, written by the same ingest
  transaction that inserted the dedup row
  (`Alplus.Observe.EventWriter.record/1`). This is a plain join, not an
  attribution guess.

  A dedup row with no matching `error_events` row (the event's partition
  was pruned by retention, or the row predates `error_events` itself --
  `error_event_deduplications` shipped in the same migration as
  `error_events`, so this should be rare) is left `source_id IS NULL` and
  counted as `unmatched`. A NULL `source_id` does not collide with any
  other row on the new `(org_id, project_id, source_id, event_id)` unique
  index (`NULL <> NULL` per row in Postgres), so it degrades to "dedup
  disabled across Sources for this one legacy event_id" rather than
  blocking ingest.

  Each batch is a keyset scan over `(event_id, org_id, project_id)`, never
  `OFFSET`, restricted to `source_id IS NULL`. `event_id` alone is NOT a
  safe cursor: after `20260816202100_add_error_event_dedup_source_index.exs`
  and `20260816201300_drop_error_event_dedup_event_id_pkey.exs`, this table
  allows several rows to share one `event_id` (different Sources, or
  different orgs/projects), so a plain `event_id > $cursor` boundary
  landing inside such a group would skip every row still sharing that
  `event_id` on the next batch. The 3-column cursor keeps a strict total
  order across the whole scanned set, so no row is skipped or
  double-applied, and a re-run after a crash or a manual stop safely
  revisits only the rows still NULL.
  """

  alias Alplus.Repo

  require Logger

  @default_batch_size 500

  @type result :: %{matched: non_neg_integer(), unmatched: non_neg_integer()}

  @spec run() :: result()
  def run do
    loop({"", "", ""}, %{matched: 0, unmatched: 0})
  end

  # Overridable only by tests (`Application.put_env(:alplus,
  # :observe_dedup_backfill_batch_size, n)`), to exercise the batch-boundary
  # keyset pagination without inserting hundreds of rows.
  defp batch_size do
    Application.get_env(:alplus, :observe_dedup_backfill_batch_size, @default_batch_size)
  end

  defp loop({cursor_event_id, cursor_org_id, cursor_project_id}, totals) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT d.event_id, d.org_id, d.project_id,
               (SELECT e.source_id FROM error_events e
                WHERE e.event_id = d.event_id
                  AND e.org_id = d.org_id
                  AND e.project_id = d.project_id
                  AND e.source_id IS NOT NULL
                LIMIT 1) AS matched_source_id
        FROM error_event_deduplications d
        WHERE d.source_id IS NULL
          AND (d.event_id, d.org_id, d.project_id) > ($1, $2, $3)
        ORDER BY d.event_id, d.org_id, d.project_id
        LIMIT $4
        """,
        [cursor_event_id, cursor_org_id, cursor_project_id, batch_size()]
      )

    case rows do
      [] ->
        Logger.info("observe dedup source_id backfill: done -- #{inspect(totals)}")
        totals

      rows ->
        batch_totals = Enum.reduce(rows, totals, &apply_row/2)

        Logger.info(
          "observe dedup source_id backfill: batch of #{length(rows)} -- #{inspect(batch_totals)}"
        )

        [event_id, org_id, project_id, _matched_source_id] = List.last(rows)
        loop({event_id, org_id, project_id}, batch_totals)
    end
  end

  defp apply_row([event_id, org_id, project_id, nil], totals) do
    Logger.warning(
      "observe dedup source_id backfill: event_id=#{event_id} (#{org_id}/#{project_id}) " <>
        "has no matching error_events row with a source_id -- left source_id NULL"
    )

    %{totals | unmatched: totals.unmatched + 1}
  end

  defp apply_row([event_id, org_id, project_id, matched_source_id], totals) do
    Repo.query!(
      "UPDATE error_event_deduplications SET source_id = $1 WHERE event_id = $2 AND org_id = $3 AND project_id = $4 AND source_id IS NULL",
      [matched_source_id, event_id, org_id, project_id]
    )

    %{totals | matched: totals.matched + 1}
  end
end
