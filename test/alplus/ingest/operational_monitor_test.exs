defmodule Alplus.Ingest.OperationalMonitorTest do
  use ExUnit.Case, async: false

  alias Alplus.Ingest.OperationalMonitor

  setup do
    original = :ets.lookup(OperationalMonitor, :notification_backlog)

    on_exit(fn ->
      :ets.delete(OperationalMonitor, :notification_backlog)
      if original != [], do: :ets.insert(OperationalMonitor, original)
    end)
  end

  test "notification admission stops at the durable backlog limit" do
    :ets.insert(OperationalMonitor, {:notification_backlog, 9_999})

    assert :ok = OperationalMonitor.reserve_notification()
    assert {:error, :backlog_full} = OperationalMonitor.reserve_notification()

    assert :ok = OperationalMonitor.release_notification()

    assert [{:notification_backlog, 9_999}] =
             :ets.lookup(OperationalMonitor, :notification_backlog)
  end
end
