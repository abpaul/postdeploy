defmodule Mix.Tasks.ObserveBackfillTasksTest do
  use Alplus.DataCase, async: false

  test "observe source_id backfill runs" do
    Mix.Tasks.Observe.BackfillSourceIds.run([])
  end

  test "observe dedup source_id backfill runs" do
    Mix.Tasks.Observe.BackfillDedupSourceIds.run([])
  end
end
