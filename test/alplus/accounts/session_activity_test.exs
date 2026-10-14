defmodule Alplus.Accounts.SessionActivityTest do
  use ExUnit.Case, async: true

  alias Alplus.Accounts.SessionActivity

  @now 1_700_000_000

  test "a session with no last_seen_at yet is not expired" do
    refute SessionActivity.expired?(nil, @now)
  end

  test "a session active within the last 7 days is not expired" do
    six_days_ago = @now - 6 * 24 * 60 * 60
    refute SessionActivity.expired?(six_days_ago, @now)
  end

  test "a session idle for more than 7 days is expired" do
    eight_days_ago = @now - 8 * 24 * 60 * 60
    assert SessionActivity.expired?(eight_days_ago, @now)
  end

  test "exactly 7 days is not yet expired" do
    exactly_seven_days_ago = @now - 7 * 24 * 60 * 60
    refute SessionActivity.expired?(exactly_seven_days_ago, @now)
  end
end
