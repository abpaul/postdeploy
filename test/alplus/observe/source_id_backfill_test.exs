defmodule Alplus.Observe.SourceIdBackfillTest do
  use ExUnit.Case, async: true

  alias Alplus.Observe.SourceIdBackfill

  defp source(id, org_id, project_id, environment, status, inserted_at) do
    %{
      id: id,
      org_id: org_id,
      project_id: project_id,
      environment: environment,
      status: status,
      inserted_at: inserted_at
    }
  end

  describe "group_by_slot/1" do
    test "groups by (org_id, project_id, environment) and sorts each group by inserted_at" do
      newer = source("src_2", "org_1", "proj_1", "production", :active, ~U[2026-02-01 00:00:00Z])
      older = source("src_1", "org_1", "proj_1", "production", :revoked, ~U[2026-01-01 00:00:00Z])
      other_env = source("src_3", "org_1", "proj_1", "staging", :active, ~U[2026-01-01 00:00:00Z])

      grouped = SourceIdBackfill.group_by_slot([newer, older, other_env])

      assert grouped[{"org_1", "proj_1", "production"}] == [older, newer]
      assert grouped[{"org_1", "proj_1", "staging"}] == [other_env]
    end
  end

  describe "attribute/2" do
    test "a timestamp inside the only Source's open-ended window matches it" do
      only = source("src_1", "org_1", "proj_1", "production", :active, ~U[2026-01-01 00:00:00Z])

      assert SourceIdBackfill.attribute([only], ~U[2026-06-01 00:00:00Z]) == {:ok, "src_1"}
    end

    test "a timestamp exactly at a Source's inserted_at belongs to that Source" do
      only = source("src_1", "org_1", "proj_1", "production", :active, ~U[2026-01-01 00:00:00Z])

      assert SourceIdBackfill.attribute([only], ~U[2026-01-01 00:00:00Z]) == {:ok, "src_1"}
    end

    test "a revoked-then-active pair splits history at the newer Source's creation" do
      revoked =
        source("src_revoked", "org_1", "proj_1", "production", :revoked, ~U[2026-01-01 00:00:00Z])

      active =
        source("src_active", "org_1", "proj_1", "production", :active, ~U[2026-03-01 00:00:00Z])

      sorted =
        SourceIdBackfill.group_by_slot([active, revoked])[{"org_1", "proj_1", "production"}]

      # Before the active Source existed: attributed to the revoked one.
      assert SourceIdBackfill.attribute(sorted, ~U[2026-02-01 00:00:00Z]) == {:ok, "src_revoked"}

      # From the active Source's creation onward: attributed to it.
      assert SourceIdBackfill.attribute(sorted, ~U[2026-03-01 00:00:00Z]) == {:ok, "src_active"}
      assert SourceIdBackfill.attribute(sorted, ~U[2026-06-01 00:00:00Z]) == {:ok, "src_active"}
    end

    test "three generations in one slot each own their own window" do
      gen1 = source("src_1", "org_1", "proj_1", "production", :revoked, ~U[2026-01-01 00:00:00Z])
      gen2 = source("src_2", "org_1", "proj_1", "production", :revoked, ~U[2026-02-01 00:00:00Z])
      gen3 = source("src_3", "org_1", "proj_1", "production", :active, ~U[2026-03-01 00:00:00Z])

      sorted =
        SourceIdBackfill.group_by_slot([gen3, gen1, gen2])[{"org_1", "proj_1", "production"}]

      assert SourceIdBackfill.attribute(sorted, ~U[2026-01-15 00:00:00Z]) == {:ok, "src_1"}
      assert SourceIdBackfill.attribute(sorted, ~U[2026-02-15 00:00:00Z]) == {:ok, "src_2"}
      assert SourceIdBackfill.attribute(sorted, ~U[2026-04-01 00:00:00Z]) == {:ok, "src_3"}
    end

    test "a timestamp older than every known Source falls back to the active Source" do
      revoked =
        source("src_revoked", "org_1", "proj_1", "production", :revoked, ~U[2026-02-01 00:00:00Z])

      active =
        source("src_active", "org_1", "proj_1", "production", :active, ~U[2026-03-01 00:00:00Z])

      sorted =
        SourceIdBackfill.group_by_slot([active, revoked])[{"org_1", "proj_1", "production"}]

      assert SourceIdBackfill.attribute(sorted, ~U[2025-01-01 00:00:00Z]) ==
               {:fallback, "src_active"}
    end

    test "with no active Source, an out-of-range timestamp falls back to the most recent one" do
      older =
        source("src_older", "org_1", "proj_1", "production", :revoked, ~U[2026-01-01 00:00:00Z])

      newer =
        source("src_newer", "org_1", "proj_1", "production", :revoked, ~U[2026-02-01 00:00:00Z])

      sorted = SourceIdBackfill.group_by_slot([newer, older])[{"org_1", "proj_1", "production"}]

      assert SourceIdBackfill.attribute(sorted, ~U[2025-01-01 00:00:00Z]) ==
               {:fallback, "src_newer"}
    end

    test "an empty slot (no Source ever existed) is unattributed" do
      assert SourceIdBackfill.attribute([], ~U[2026-01-01 00:00:00Z]) == :unattributed
    end
  end

  describe "group_by_slot/1 with a tied inserted_at" do
    test "two Sources created at the identical instant sort deterministically by id, regardless of input order" do
      a = source("src_b", "org_1", "proj_1", "production", :revoked, ~U[2026-01-01 00:00:00Z])
      b = source("src_a", "org_1", "proj_1", "production", :active, ~U[2026-01-01 00:00:00Z])

      forward = SourceIdBackfill.group_by_slot([a, b])[{"org_1", "proj_1", "production"}]
      reversed = SourceIdBackfill.group_by_slot([b, a])[{"org_1", "proj_1", "production"}]

      # Same result whichever order the source rows arrive in (the real
      # query has no ORDER BY) -- id breaks the tie, not input position.
      assert forward == [b, a]
      assert reversed == [b, a]
    end

    test "a timestamp exactly at the tie attributes to the higher-id Source, without crashing" do
      earlier_id =
        source("src_1", "org_1", "proj_1", "production", :revoked, ~U[2026-01-01 00:00:00Z])

      later_id =
        source("src_2", "org_1", "proj_1", "production", :active, ~U[2026-01-01 00:00:00Z])

      sorted =
        SourceIdBackfill.group_by_slot([later_id, earlier_id])[{"org_1", "proj_1", "production"}]

      assert SourceIdBackfill.attribute(sorted, ~U[2026-01-01 00:00:00Z]) == {:ok, "src_2"}

      # A moment strictly before the tie still falls back sanely, no crash.
      assert SourceIdBackfill.attribute(sorted, ~U[2025-12-31 00:00:00Z]) ==
               {:fallback, "src_2"}
    end
  end
end
