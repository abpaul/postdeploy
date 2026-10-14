defmodule AlplusWeb.StatusHTMLTest do
  use ExUnit.Case, async: true

  alias AlplusWeb.StatusHTML

  test "daily detail includes monitoring coverage and incident pause counts" do
    detail =
      StatusHTML.day_detail(%{
        state: :up,
        uptime: 1.0,
        downtime: 60_000_000,
        monitored_microseconds: 60_000_000,
        check_count: 4,
        incident_count: 1,
        pause_count: 2,
        partial?: true
      })

    assert detail =~ "Operational"
    assert detail =~ "100.0% uptime"
    assert detail =~ "1m down"
    assert detail =~ "1 incidents"
    assert detail =~ "2 pauses"
    assert detail =~ "4 checks"
    assert detail =~ "partial today"
  end

  test "daily detail distinguishes partial retention from no evidence" do
    partial =
      StatusHTML.day_detail(%{
        state: :partial,
        monitored_microseconds: 300_000_000,
        check_count: 1,
        incident_count: 0,
        pause_count: 0,
        partial?: false
      })

    unknown =
      StatusHTML.day_detail(%{
        state: :unknown,
        monitored_microseconds: 0,
        check_count: 0,
        incident_count: 0,
        pause_count: 0,
        partial?: false
      })

    assert partial =~ "Partial evidence"
    assert partial =~ "monitored 5m"
    assert unknown =~ "No data"
    assert unknown =~ "no checks"
  end

  test "public status labels make absent observations explicit" do
    assert StatusHTML.status_label(:unknown) == "No observations yet"
    assert StatusHTML.banner_icon(:unknown) == "hero-question-mark-circle"
  end
end
