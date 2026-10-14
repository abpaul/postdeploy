defmodule Alplus.Monitoring.AnonymousProbe.GateTest do
  use ExUnit.Case, async: false

  alias Alplus.Monitoring.AnonymousProbe.{Gate, RateLimiter}

  test "admits one probe per journey and releases it" do
    journey = "journey-" <> Integer.to_string(System.unique_integer([:positive]))

    assert :ok = Gate.admit(journey)
    assert {:error, :journey_busy} = Gate.admit(journey)
    assert :ok = Gate.release(journey)
    assert :ok = Gate.admit(journey)
    assert :ok = Gate.release(journey)
  end

  # Both limits are asserted under a scope of this test's own. The limiter
  # counts every caller on the node in one ETS table, so a shared scope would
  # arrive with the global budget already spent by whatever ran before.
  test "the limiter returns a retry time once the per-IP budget is spent" do
    put_limiter_config(ip_limit: 1, global_limit: 1_000)

    ip = unique_ip()
    assert :ok = RateLimiter.check(ip)
    assert {:error, retry_after} = RateLimiter.check(ip)
    assert retry_after >= 1
  end

  test "the limiter returns a retry time once the global budget is spent" do
    put_limiter_config(ip_limit: 1_000, global_limit: 1)

    assert :ok = RateLimiter.check(unique_ip())
    assert {:error, retry_after} = RateLimiter.check(unique_ip())
    assert retry_after >= 1
  end

  defp put_limiter_config(opts) do
    previous = Application.get_env(:alplus, RateLimiter, [])
    scope = "test-#{System.unique_integer([:positive])}"

    Application.put_env(
      :alplus,
      RateLimiter,
      Keyword.merge([window_ms: 60_000, scope: scope], opts)
    )

    on_exit(fn -> Application.put_env(:alplus, RateLimiter, previous) end)
  end

  defp unique_ip do
    {203, 0, 113, rem(System.unique_integer([:positive]), 200) + 1}
  end
end
