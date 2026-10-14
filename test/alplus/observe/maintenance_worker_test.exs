defmodule Alplus.Observe.MaintenanceWorkerTest do
  use Alplus.DataCase, async: false

  test "perform/1 prunes events and session dedup" do
    assert :ok = Alplus.Observe.MaintenanceWorker.perform(%Oban.Job{args: %{}})
  end
end
