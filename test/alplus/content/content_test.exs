defmodule Alplus.ContentTest do
  @moduledoc """
  Content is public and not tenant-owned (ARCHITECTURE.md §3): every create
  below passes `authorize?: false` since no policy authorizes a write, and
  every read goes through the domain code interface with no actor, since
  the marketing site itself is unauthenticated.
  """

  use Alplus.DataCase, async: true

  alias Alplus.Content
  alias Alplus.Content.{Comparison, Guide, Page}

  describe "Page" do
    test "creates and reads a published page through the domain interface" do
      assert {:ok, page} =
               Content.create_page(
                 %{
                   slug: "pricing",
                   path: "/pricing",
                   title: "Pricing | PostDeploy",
                   meta_description: "Plans for one project, ten or fifty.",
                   summary: "PostDeploy plans and enforced allowances.",
                   lastmod: ~D[2026-08-03],
                   group: "core",
                   priority: "1.0",
                   cluster: "pricing",
                   intent: "transactional",
                   primary_query: "test pricing query"
                 },
                 authorize?: false
               )

      assert page.slug == "pricing"
      assert page.status == "published"

      assert {:ok, by_path} = Content.get_page_by_path("/pricing")
      assert by_path.id == page.id

      assert {:ok, by_slug} = Content.get_page_by_slug("pricing")
      assert by_slug.id == page.id
    end

    test "a draft page is invisible to the public (no actor) read" do
      {:ok, _page} =
        Content.create_page(
          %{
            slug: "unlisted",
            path: "/unlisted",
            title: "Unlisted",
            meta_description: "Not public yet.",
            summary: "Draft.",
            lastmod: ~D[2026-08-03],
            status: "draft",
            cluster: "pricing",
            intent: "transactional",
            primary_query: "test draft query"
          },
          authorize?: false
        )

      # get? actions raise NotFound rather than returning {:ok, nil} — the
      # policy filters the row out before the get? "must match one" check.
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Content.get_page_by_path("/unlisted")

      # The internal read (bypassing the policy) proves the row exists —
      # this is a policy filter, not a missing row.
      assert {:ok, %Page{}} = Content.get_page_by_path("/unlisted", authorize?: false)
    end

    test "create without authorize?: false is rejected" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Content.create_page(%{
                 slug: "bypass",
                 path: "/bypass",
                 title: "Bypass",
                 meta_description: "x",
                 summary: "x",
                 lastmod: ~D[2026-08-03],
                 cluster: "pricing",
                 intent: "transactional",
                 primary_query: "test bypass query"
               })

      refute Repo.exists?(from p in Page, where: p.slug == "bypass")
    end

    test "update without authorize?: false is rejected" do
      {:ok, page} =
        Content.create_page(
          %{
            slug: "locked",
            path: "/locked",
            title: "Locked",
            meta_description: "x",
            summary: "x",
            lastmod: ~D[2026-08-03],
            cluster: "pricing",
            intent: "transactional",
            primary_query: "test locked query"
          },
          authorize?: false
        )

      assert {:error, %Ash.Error.Forbidden{}} =
               Content.update_page(page, %{title: "Changed"})
    end
  end

  describe "Guide" do
    test "creates and reads a published guide with structured body sections and faqs" do
      assert {:ok, guide} =
               Content.create_guide(
                 %{
                   slug: "free-cron-job-monitoring",
                   path: "/free-cron-job-monitoring",
                   title: "Free cron job monitoring | PostDeploy",
                   meta_description: "Monitor cron jobs free with a curl heartbeat.",
                   summary: "How to monitor cron jobs with a curl heartbeat.",
                   lastmod: ~D[2026-08-03],
                   cluster: "cron",
                   intent: "transactional",
                   primary_query: "test free cron query",
                   body_sections: [
                     %{
                       "heading" => "How to monitor a cron job with curl",
                       "body" => ["Append a curl ping to the end of your cron command."]
                     }
                   ],
                   faqs: [
                     %{
                       "q" => "Do I need to install an agent?",
                       "a" => "No, it is one outbound HTTPS request."
                     }
                   ]
                 },
                 authorize?: false
               )

      assert {:ok, by_path} = Content.get_guide_by_path("/free-cron-job-monitoring")
      assert by_path.id == guide.id
      assert [%{"heading" => _}] = guide.body_sections
      assert [%{"q" => _, "a" => _}] = guide.faqs
    end

    test "create without authorize?: false is rejected" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Content.create_guide(%{
                 slug: "bypass-guide",
                 path: "/bypass-guide",
                 title: "Bypass",
                 meta_description: "x",
                 summary: "x",
                 lastmod: ~D[2026-08-03],
                 cluster: "cron",
                 intent: "transactional",
                 primary_query: "test bypass guide query"
               })

      refute Repo.exists?(from g in Guide, where: g.slug == "bypass-guide")
    end

    # SITE-ARCHITECTURE.md §8 publish gate. Only fires when `docs_host` is
    # set, so ordinary guides (asserted above with none of these fields) are
    # unaffected; these attrs vary one field at a time from a valid base.
    defp heartbeat_guide_attrs(overrides) do
      Map.merge(
        %{
          slug: "example-heartbeat",
          path: "/guides/example-heartbeat",
          title: "Monitor an Example scheduled job | PostDeploy",
          meta_description: "How Example jobs fail silently, and how to catch it.",
          summary: "Detect Example's silent scheduling failure with a heartbeat.",
          lastmod: ~D[2026-09-04],
          last_verified_on: ~D[2026-09-04],
          cluster: "cron",
          intent: "informational",
          primary_query: "test example heartbeat query",
          platform: "Example",
          docs_host: "docs.example.com",
          platform_failure_mode: "Example disables a schedule after 60 days of inactivity.",
          sources: [
            %{
              "label" => "Example scheduling docs",
              "url" => "https://docs.example.com/scheduling",
              "retrieved" => "2026-09-04"
            }
          ],
          not_offered: ["PostDeploy does not read Example's internal logs"]
        },
        overrides
      )
    end

    test "a heartbeat guide with a source host that does not match docs_host is rejected" do
      attrs =
        heartbeat_guide_attrs(%{
          slug: "mismatched-host-heartbeat",
          path: "/guides/mismatched-host-heartbeat",
          sources: [
            %{
              "label" => "Wrong host",
              "url" => "https://other-vendor.example/scheduling",
              "retrieved" => "2026-09-04"
            }
          ]
        })

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Content.create_guide(attrs, authorize?: false)

      assert Enum.any?(errors, &(&1.field == :sources))
      refute Repo.exists?(from g in Guide, where: g.slug == "mismatched-host-heartbeat")
    end

    test "a heartbeat guide with a stale source retrieval date is rejected" do
      attrs =
        heartbeat_guide_attrs(%{
          slug: "stale-source-heartbeat",
          path: "/guides/stale-source-heartbeat",
          sources: [
            %{
              "label" => "Old citation",
              "url" => "https://docs.example.com/scheduling",
              "retrieved" => "2020-01-01"
            }
          ]
        })

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Content.create_guide(attrs, authorize?: false)

      assert Enum.any?(errors, &(&1.field == :sources))
      refute Repo.exists?(from g in Guide, where: g.slug == "stale-source-heartbeat")
    end

    test "a heartbeat guide with an empty not_offered list is rejected" do
      attrs =
        heartbeat_guide_attrs(%{
          slug: "no-not-offered-heartbeat",
          path: "/guides/no-not-offered-heartbeat",
          not_offered: []
        })

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Content.create_guide(attrs, authorize?: false)

      assert Enum.any?(errors, &(&1.field == :not_offered))
      refute Repo.exists?(from g in Guide, where: g.slug == "no-not-offered-heartbeat")
    end

    test "a heartbeat guide that satisfies every publish gate rule is created" do
      attrs = heartbeat_guide_attrs(%{})

      assert {:ok, guide} = Content.create_guide(attrs, authorize?: false)
      assert guide.docs_host == "docs.example.com"
      assert guide.not_offered == ["PostDeploy does not read Example's internal logs"]
    end

    test "a non-heartbeat guide with no docs_host is unaffected by the publish gate" do
      assert {:ok, _guide} =
               Content.create_guide(
                 %{
                   slug: "plain-guide",
                   path: "/plain-guide",
                   title: "Plain guide",
                   meta_description: "No docs_host, no gate.",
                   summary: "Ordinary content page.",
                   lastmod: ~D[2026-08-03],
                   cluster: "guides",
                   intent: "informational",
                   primary_query: "test plain guide query"
                 },
                 authorize?: false
               )
    end
  end

  describe "Comparison" do
    test "creates and reads a published competitor comparison" do
      assert {:ok, comparison} =
               Content.create_comparison(
                 %{
                   slug: "cronitor",
                   path: "/alternatives/cronitor",
                   title: "Cronitor alternative | PostDeploy",
                   meta_description: "An honest Cronitor comparison.",
                   summary: "PostDeploy compared with Cronitor.",
                   lastmod: ~D[2026-08-03],
                   cluster: "comparison",
                   intent: "commercial_investigation",
                   primary_query: "test cronitor alternative query",
                   competitor_name: "Cronitor",
                   competitor_homepage: "https://cronitor.io/",
                   positioning: "Cronitor sells a developer monitoring suite.",
                   tldr: "Cronitor is a deeper cron monitor than PostDeploy today.",
                   why_looking: ["The free tier runs out at five monitors."],
                   free_tier_rows: [
                     %{
                       "label" => "Uptime and API monitors, free plan",
                       "them" => "5 shared with jobs",
                       "edge" => "us"
                     }
                   ],
                   they_do_better: ["Job semantics we do not have."],
                   we_do_better: ["Separate allowances instead of one pool."],
                   stay_with_them: ["You need overlap detection."],
                   switch_to_us: ["You want one flat bill."],
                   migration: ["Every job's ping URL changes."],
                   unverified: ["Free-tier alerting channels disagree on-page."],
                   faqs: [%{"q" => "Is PostDeploy a drop-in replacement?", "a" => "No."}],
                   sources: [
                     %{
                       "label" => "Plan tiers",
                       "url" => "https://cronitor.io/pricing",
                       "retrieved" => "2026-08-03"
                     }
                   ]
                 },
                 authorize?: false
               )

      assert {:ok, by_slug} = Content.get_comparison_by_slug("cronitor")
      assert by_slug.id == comparison.id
      assert comparison.competitor_name == "Cronitor"
      assert [%{"label" => _, "them" => _, "edge" => "us"}] = comparison.free_tier_rows
    end

    test "create without authorize?: false is rejected" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Content.create_comparison(%{
                 slug: "bypass-cmp",
                 path: "/alternatives/bypass-cmp",
                 title: "Bypass",
                 meta_description: "x",
                 summary: "x",
                 lastmod: ~D[2026-08-03],
                 cluster: "comparison",
                 intent: "commercial_investigation",
                 primary_query: "test bypass comparison query",
                 competitor_name: "X",
                 competitor_homepage: "https://example.com",
                 positioning: "x",
                 tldr: "x"
               })

      refute Repo.exists?(from c in Comparison, where: c.slug == "bypass-cmp")
    end
  end
end
