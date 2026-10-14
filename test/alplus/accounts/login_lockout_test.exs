defmodule Alplus.Accounts.LoginLockoutTest do
  use ExUnit.Case, async: true

  alias Alplus.Accounts.LoginLockout

  @now ~U[2026-01-01 12:00:00Z]

  setup do
    key = {:email, "lockout-unit-#{System.unique_integer([:positive])}@example.com"}
    on_exit(fn -> LoginLockout.clear(key) end)
    {:ok, key: key}
  end

  test "not locked before any failures", %{key: key} do
    refute LoginLockout.locked?(key, @now)
  end

  test "locks after 10 failures within the 15-minute window", %{key: key} do
    for i <- 1..9 do
      LoginLockout.record_failure(key, DateTime.add(@now, i, :second))
      refute LoginLockout.locked?(key, DateTime.add(@now, i, :second))
    end

    LoginLockout.record_failure(key, DateTime.add(@now, 10, :second))
    assert LoginLockout.locked?(key, DateTime.add(@now, 10, :second))
  end

  test "old failures outside the window don't count toward the lock", %{key: key} do
    for i <- 1..10 do
      LoginLockout.record_failure(key, DateTime.add(@now, i, :second))
    end

    assert LoginLockout.locked?(key, DateTime.add(@now, 10, :second))

    sixteen_minutes_later = DateTime.add(@now, 16 * 60, :second)
    refute LoginLockout.locked?(key, sixteen_minutes_later)
  end

  test "clear/1 resets the counter", %{key: key} do
    for i <- 1..10 do
      LoginLockout.record_failure(key, DateTime.add(@now, i, :second))
    end

    assert LoginLockout.locked?(key, @now)

    LoginLockout.clear(key)

    refute LoginLockout.locked?(key, @now)
  end

  test "email and IP counters are independent" do
    email_key = {:email, "isolated-#{System.unique_integer([:positive])}@example.com"}
    ip_key = {:ip, "203.0.113.#{rem(System.unique_integer([:positive]), 254) + 1}"}

    for i <- 1..10, do: LoginLockout.record_failure(email_key, DateTime.add(@now, i, :second))

    assert LoginLockout.locked?(email_key, @now)
    refute LoginLockout.locked?(ip_key, @now)

    LoginLockout.clear(email_key)
  end

  describe "sweep/1" do
    test "deletes keys whose failures all fell out of the window", %{key: key} do
      LoginLockout.record_failure(key, @now)
      assert LoginLockout.count(key, @now) == 1

      LoginLockout.sweep(DateTime.add(@now, 16 * 60, :second))

      assert :ets.lookup(LoginLockout, key) == []
    end

    test "keeps keys with failures still inside the window", %{key: key} do
      LoginLockout.record_failure(key, @now)
      recent = DateTime.add(@now, 14 * 60, :second)
      LoginLockout.record_failure(key, recent)

      LoginLockout.sweep(recent)

      assert LoginLockout.count(key, recent) == 2
      assert [{^key, _}] = :ets.lookup(LoginLockout, key)
    end
  end
end
