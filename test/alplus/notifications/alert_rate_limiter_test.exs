defmodule Alplus.Notifications.AlertRateLimiterTest do
  use ExUnit.Case, async: false

  alias Alplus.Notifications.AlertRateLimiter

  setup do
    :ets.delete_all_objects(AlertRateLimiter)
    on_exit(fn -> :ets.delete_all_objects(AlertRateLimiter) end)
    :ok
  end

  test "one organization cannot create more than 60 alert jobs per minute" do
    for _alert <- 1..60, do: assert(:ok = AlertRateLimiter.check("noisy"))
    assert {:error, :tenant_limit} = AlertRateLimiter.check("noisy")
    assert :ok = AlertRateLimiter.check("normal")
  end

  test "all organizations share a finite global alert budget" do
    for organization <- 1..10, _alert <- 1..60 do
      assert :ok = AlertRateLimiter.check("organization-#{organization}")
    end

    assert {:error, :global_limit} = AlertRateLimiter.check("organization-11")
  end
end
