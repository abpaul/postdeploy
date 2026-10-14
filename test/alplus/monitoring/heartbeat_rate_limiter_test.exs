defmodule Alplus.Monitoring.HeartbeatRateLimiterTest do
  use ExUnit.Case, async: false

  alias Alplus.Monitoring.HeartbeatRateLimiter

  setup do
    :ets.delete_all_objects(HeartbeatRateLimiter)
    :ok
  end

  test "the absolute safety limit rejects one heartbeat token without affecting another" do
    for _request <- 1..120, do: assert(:ok = HeartbeatRateLimiter.check("noisy"))

    assert {:error, retry_after} = HeartbeatRateLimiter.check("noisy")
    assert retry_after >= 1
    assert :ok = HeartbeatRateLimiter.check("normal")
  end
end
