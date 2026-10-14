defmodule Alplus.Content.SeedsTest do
  @moduledoc """
  Running the seed twice must not duplicate rows (BUILD.md Phase 4): every
  create uses `upsert?: true` on the resource's slug identity.
  """

  use Alplus.DataCase, async: true
  alias Alplus.Content.{Comparison, Guide, Page}
  alias Alplus.Content.Seeds

  test "running the seed twice leaves marketing rows unchanged" do
    assert :ok = Seeds.run()

    counts_after_first_run = %{
      pages: Repo.aggregate(Page, :count),
      guides: Repo.aggregate(Guide, :count),
      comparisons: Repo.aggregate(Comparison, :count)
    }

    assert counts_after_first_run.pages >= 3
    assert counts_after_first_run.guides >= 2
    assert counts_after_first_run.comparisons >= 4

    assert :ok = Seeds.run()

    counts_after_second_run = %{
      pages: Repo.aggregate(Page, :count),
      guides: Repo.aggregate(Guide, :count),
      comparisons: Repo.aggregate(Comparison, :count)
    }

    assert counts_after_second_run == counts_after_first_run
  end

  test "the seeded pages, guides and comparisons are readable published content" do
    Seeds.run()

    assert {:ok, home} = Alplus.Content.get_page_by_path("/")
    assert home.status == "published"

    assert {:ok, cron_guide} = Alplus.Content.get_guide_by_path("/free-cron-job-monitoring")
    assert cron_guide.status == "published"
    assert cron_guide.body_sections != []

    assert {:ok, cronitor} = Alplus.Content.get_comparison_by_slug("cronitor")
    assert cronitor.status == "published"
    assert cronitor.free_tier_rows != []
  end
end
