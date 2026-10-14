defmodule Alplus.Measure.VisitorHashTest do
  use Alplus.DataCase, async: true

  alias Alplus.Measure.VisitorHash
  alias Alplus.Measure.VisitorSalt

  # `hash/5` is a short-lived pseudonymous value persisted only in the
  # day-scoped seen table. It must express the same site boundary as the
  # `{source_id, visitor_hash}` visit-state key (ADR 0002), so one browser
  # visiting two Measure sites in the same project never shares identity
  # across that site boundary.
  test "the same project, IP, user agent, and timestamp yield different hashes for different source ids" do
    now = DateTime.utc_now()
    ip = {203, 0, 113, 10}
    ua = "Mozilla/5.0 (test)"

    hash_a = VisitorHash.hash("project_1", "source_a", ip, ua, now)
    hash_b = VisitorHash.hash("project_1", "source_b", ip, ua, now)

    refute hash_a == hash_b
  end

  test "the same project, source id, IP, user agent, and timestamp yield the same hash" do
    now = DateTime.utc_now()
    ip = {203, 0, 113, 10}
    ua = "Mozilla/5.0 (test)"

    assert VisitorHash.hash("project_1", "source_a", ip, ua, now) ==
             VisitorHash.hash("project_1", "source_a", ip, ua, now)
  end

  test "pruning a day's salt makes the next hash for that day a new value" do
    day = ~D[2020-01-01]
    now = DateTime.new!(day, ~T[12:00:00], "Etc/UTC")
    ip = {203, 0, 113, 10}
    ua = "Mozilla/5.0 (test)"

    first = VisitorHash.hash("project_1", "source_a", ip, ua, now)
    assert VisitorSalt.prune(~D[2020-01-03]) >= 1
    second = VisitorHash.hash("project_1", "source_a", ip, ua, now)

    refute first == second
  end
end
