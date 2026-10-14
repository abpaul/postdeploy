defmodule Alplus.Billing.PackageTest do
  use ExUnit.Case, async: true

  alias Alplus.Billing.Package

  test "the limit set is closed: an unknown key raises instead of inventing a value" do
    assert_raise KeyError, fn -> Package.limit(:logs_bytes_per_month) end
  end

  test "the event ceiling adds the grace band and rounds down" do
    grace = Package.get().event_grace_percent

    assert Package.event_ceiling(100) == 100 + grace
    assert Package.event_ceiling(1) == div(100 + grace, 100)
  end

  test "feature ids are unique, because the console and pricing page use them as DOM ids" do
    features = Package.get().features
    assert Enum.uniq_by(features, & &1.id) == features
  end
end
