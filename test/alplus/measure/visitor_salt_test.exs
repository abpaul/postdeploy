defmodule Alplus.Measure.VisitorSaltTest do
  use Alplus.DataCase, async: true

  alias Alplus.Measure.VisitorSalt

  test "fetch! returns the same 32-byte salt for one day" do
    day = ~D[2026-08-18]
    salt = VisitorSalt.fetch!(day)

    assert byte_size(salt) == 32
    assert VisitorSalt.fetch!(day) == salt
  end

  test "prune deletes salts older than yesterday and drops them from ETS" do
    old = ~D[2026-08-01]
    yesterday = ~D[2026-08-17]
    today = ~D[2026-08-18]

    old_salt = VisitorSalt.fetch!(old)
    keep_salt = VisitorSalt.fetch!(yesterday)
    today_salt = VisitorSalt.fetch!(today)

    for {day, hash} <- [
          {old, String.duplicate("a", 64)},
          {yesterday, String.duplicate("b", 64)},
          {today, String.duplicate("c", 64)}
        ] do
      Alplus.Repo.query!(
        "INSERT INTO measure_visitor_seen (day, visitor_hash, inserted_at) VALUES ($1, $2, now())",
        [day, hash]
      )
    end

    assert VisitorSalt.prune(today) == 1

    assert %{rows: [[2]]} =
             Alplus.Repo.query!("SELECT count(*) FROM measure_visitor_seen")

    assert VisitorSalt.fetch!(yesterday) == keep_salt
    assert VisitorSalt.fetch!(today) == today_salt
    refute VisitorSalt.fetch!(old) == old_salt
  end
end
