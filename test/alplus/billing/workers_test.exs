defmodule Alplus.Billing.WorkersTest do
  use Alplus.DataCase, async: false

  test "reconciliation worker cancels when no adapter is configured" do
    previous = Application.get_env(:alplus, :stripe_reconciliation_adapter)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:alplus, :stripe_reconciliation_adapter, previous),
        else: Application.delete_env(:alplus, :stripe_reconciliation_adapter)
    end)

    Application.delete_env(:alplus, :stripe_reconciliation_adapter)

    assert {:cancel, _} =
             Alplus.Billing.ReconciliationWorker.perform(%Oban.Job{
               args: %{"stripe_environment" => "local"}
             })

    assert {:cancel, _} = Alplus.Billing.ReconciliationWorker.perform(%Oban.Job{args: %{}})
  end

  test "usage rollover worker returns :ok" do
    assert :ok = Alplus.Billing.UsageRolloverWorker.perform(%Oban.Job{args: %{}})
  end
end
