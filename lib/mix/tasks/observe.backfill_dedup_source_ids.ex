defmodule Mix.Tasks.Observe.BackfillDedupSourceIds do
  @moduledoc """
  Backfills `error_event_deduplications.source_id` from the matching
  `error_events` row's `source_id` (issue #46 follow-up, see the "Observe
  error-event dedup" section in `docs/observe-source-id-phase-b.md`). Run
  after `20260816202000_add_error_event_dedup_source_id.exs` and before
  `20260816202100_add_error_event_dedup_source_index.exs` so as few rows as
  possible are still NULL when the composite unique index is built.

  Idempotent and resumable: every batch re-selects rows still missing
  `source_id`. See `Alplus.Observe.DedupSourceIdBackfill` for the join and
  batching.
  """

  use Mix.Task

  @shortdoc "Backfills error_event_deduplications.source_id from error_events"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:alplus)

    result = Alplus.Observe.DedupSourceIdBackfill.run()
    Mix.shell().info("error_event_deduplications: #{inspect(result)}")
  end
end
