defmodule Alplus.ReleaseTest do
  @moduledoc """
  `Alplus.Release.seed/0` runs on every container boot.

  It exists because production was migrated but never seeded, so every
  content-backed page returned 404 while `/health` still returned `ok`: a
  green deploy with no public pricing page. These tests pin the two
  properties that make running it on boot safe.
  """

  use Alplus.DataCase, async: false

  alias Alplus.Content.{Comparison, Guide, Page}

  defp counts do
    %{
      pages: Repo.aggregate(Page, :count),
      guides: Repo.aggregate(Guide, :count),
      comparisons: Repo.aggregate(Comparison, :count)
    }
  end

  test "publishes content into an empty database" do
    # The exact production state: schema present, content tables empty.
    Repo.query!("DELETE FROM content_guides")
    Repo.query!("DELETE FROM content_pages")
    Repo.query!("DELETE FROM content_comparisons")

    assert counts() == %{pages: 0, guides: 0, comparisons: 0}

    # Calls the release task itself, not `Content.Seeds.run/0` underneath it.
    # The task is what the container runs on boot, so testing the inner
    # function would leave the boot path unexercised.
    Alplus.Release.seed()

    after_seed = counts()
    assert after_seed.pages >= 3
    assert after_seed.guides >= 9
    assert after_seed.comparisons >= 4
  end

  test "is idempotent, so running on every boot cannot duplicate rows" do
    Alplus.Release.seed()
    first = counts()

    Alplus.Release.seed()
    Alplus.Release.seed()

    assert counts() == first
  end

  test "a content failure is logged rather than raised" do
    # Boot policy: a seed problem must not crash the container, because the
    # app still serves the console and ingest without content rows.
    # Migrations keep the opposite policy on purpose.
    #
    # Forced by breaking a CHECK constraint the seed data must satisfy: the
    # title length limit. A raise here would take the whole site down on boot.
    Repo.query!(
      "ALTER TABLE content_pages ADD CONSTRAINT tmp_force_seed_failure CHECK (octet_length(title) < 3)"
    )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert [{:ok, _, _}] = Alplus.Release.seed()
      end)

    assert log =~ "marketing content seeding failed"
    assert log =~ "bin/alplus eval"
  after
    Repo.query!("ALTER TABLE content_pages DROP CONSTRAINT IF EXISTS tmp_force_seed_failure")
  end
end
