defmodule Mix.Tasks.Observe.BackfillSourceIds do
  @moduledoc """
  Backfills `source_id` on `issues`, `releases`, `error_events`, and
  `observe_session_rollups` from each row's own timestamp and the Source
  lifecycle window that contains it (issue #46 follow-up: each Observe
  Source must own its own error events, issues, releases, and session
  rollups). Run after the expand migrations
  (`20260816193722_add_observe_source_id.exs`,
  `20260816184000_add_error_events_source_id.exs`,
  `20260816184100_add_error_events_source_id_index.exs`,
  `20260816194015_add_session_rollup_source_id.exs`) and before deploying
  the read-side and ingest changes that assume `source_id` is populated.

  Idempotent and resumable: every batch re-selects rows still missing
  `source_id`, so running it twice, or restarting it after an interruption,
  never double-applies or loses progress. See `Alplus.Observe.SourceIdBackfill`
  for the attribution rule and `Alplus.Observe.SourceIdBackfill.Runner` for
  the batched execution.
  """

  use Mix.Task

  @shortdoc "Backfills issues/releases/error_events.source_id from Source lifecycle windows"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:alplus)

    results = Alplus.Observe.SourceIdBackfill.Runner.run()

    Enum.each(results, fn {table, counts} ->
      Mix.shell().info("#{table}: #{inspect(counts)}")
    end)
  end
end
