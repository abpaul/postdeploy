defmodule Alplus.Measure.MaintenanceWorkerTest do
  use Alplus.DataCase, async: false

  test "perform/1 prunes salts and returns :ok" do
    assert :ok = Alplus.Measure.MaintenanceWorker.perform(%Oban.Job{args: %{}})
  end
end
