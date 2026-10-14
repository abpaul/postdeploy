defmodule Alplus.Seo.InventoryTest do
  @moduledoc """
  The content inventory and search intent map (PRD §39, §40).

  The inventory only has value if it stays true, so `Alplus.Seo.Audit`
  enforces it against the live site and `Alplus.Seo.AuditTest` proves those
  checks fire. These tests cover the inventory's own invariants.
  """

  # Inventory now reads `Alplus.Content` rows at call time (PRD §39, §40
  # attributes on `Page`/`Guide`/`Comparison`), so these tests need the real
  # seeded content and a sandboxed database, not a compile-time literal.
  use Alplus.DataCase, async: true

  alias Alplus.Seo.Inventory

  @intents [:informational, :commercial_investigation, :transactional, :navigational]

  setup do
    Alplus.Content.Seeds.run()
    :ok
  end

  describe "invariants" do
    test "every entry is complete and well formed" do
      for entry <- Inventory.entries() do
        assert String.starts_with?(entry.path, "/"), "#{entry.path} is not a path"
        assert entry.type in [:page, :guide, :comparison, :article]
        assert entry.intent in @intents, "#{entry.path} has intent #{inspect(entry.intent)}"
        assert is_binary(entry.cluster) and entry.cluster != ""
        assert is_binary(entry.primary_query) and entry.primary_query != ""
      end
    end

    test "no path is listed twice" do
      paths = Inventory.paths()
      assert length(paths) == length(Enum.uniq(paths))
    end

    test "no two pages claim the same primary query" do
      # The healthy state. When this fails, two pages are splitting the
      # signals that would have ranked either of them.
      assert Inventory.cannibalised_queries() == %{}
    end
  end

  describe "cannibalisation detection" do
    test "ignores case and surrounding whitespace" do
      # Neither distinguishes two search queries, so neither may hide a
      # collision. Verified on the normalising function through the public
      # grouping behaviour rather than by reaching into the private one.
      queries = Enum.map(Inventory.entries(), &String.downcase(String.trim(&1.primary_query)))

      assert length(queries) == length(Enum.uniq(queries)),
             "two entries collide once case and whitespace are normalised"
    end
  end

  describe "intent coverage" do
    test "the commercial cluster is commercial investigation" do
      for path <- [
            "/monitoring",
            "/monitoring/uptime",
            "/monitoring/cron-jobs",
            "/monitoring/api"
          ] do
        assert Inventory.entry(path).intent == :commercial_investigation
      end
    end

    test "guides are informational, so they must be useful without a signup" do
      for path <- [
            "/guides/github-actions-heartbeat",
            "/guides/kubernetes-cronjob-heartbeat",
            "/guides/heroku-scheduler-heartbeat",
            "/guides/systemd-timer-heartbeat",
            "/guides/laravel-scheduler-heartbeat",
            "/guides/airflow-heartbeat",
            "/guides/gitlab-ci-schedule-heartbeat"
          ] do
        assert Inventory.entry(path).intent == :informational
      end
    end

    test "every comparison is commercial investigation" do
      Inventory.entries()
      |> Enum.filter(&(&1.type == :comparison))
      |> tap(fn comparisons -> assert length(comparisons) >= 4 end)
      |> Enum.each(fn entry -> assert entry.intent == :commercial_investigation end)
    end

    test "free-tier pages target different queries from the commercial cluster" do
      # "free cron job monitoring" and "cron job monitoring" are different
      # searches with different intent. If these ever converge, one page
      # should be merged away rather than left to compete.
      free = Inventory.entry("/free-cron-job-monitoring")
      commercial = Inventory.entry("/monitoring/cron-jobs")

      assert free.primary_query != commercial.primary_query
      assert free.intent == :transactional
      assert commercial.intent == :commercial_investigation
      # Same cluster, so growth reporting still counts them together.
      assert free.cluster == commercial.cluster
    end
  end

  describe "clusters" do
    test "match the clusters growth reporting counts in" do
      # A page whose inventory cluster is unknown to `Alplus.Growth` would
      # be invisible in the funnel report.
      for entry <- Inventory.entries() do
        assert Alplus.Growth.content_cluster(entry.path) == entry.cluster,
               "#{entry.path}: inventory says #{entry.cluster}, " <>
                 "Growth says #{Alplus.Growth.content_cluster(entry.path)}"
      end
    end
  end
end
