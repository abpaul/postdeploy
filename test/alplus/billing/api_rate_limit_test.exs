defmodule Alplus.Billing.ApiRateLimitTest do
  use ExUnit.Case, async: false

  alias Alplus.Billing.Package
  alias Alplus.Measure.RateLimiter, as: MeasureRateLimiter
  alias Alplus.Observe.RateLimiter, as: ObserveRateLimiter

  test "Measure enforces the package API rate limit" do
    :ets.delete_all_objects(MeasureRateLimiter)
    key = "measure-rate-#{System.unique_integer([:positive])}"

    for _ <- 1..Package.limit(:api_rate_limit_per_minute) do
      assert :ok = MeasureRateLimiter.check(key)
    end

    assert {:error, retry_after} = MeasureRateLimiter.check(key)
    assert retry_after >= 1
  end

  test "Observe enforces the package API rate limit" do
    :ets.delete_all_objects(ObserveRateLimiter)
    key = "observe-rate-#{System.unique_integer([:positive])}"

    for _ <- 1..Package.limit(:api_rate_limit_per_minute) do
      assert :ok = ObserveRateLimiter.check(key)
    end

    assert {:error, retry_after} = ObserveRateLimiter.check(key)
    assert retry_after >= 1
  end
end
