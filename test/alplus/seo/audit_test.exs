defmodule Alplus.Seo.AuditTest do
  @moduledoc """
  Runs the SEO audit over every public route and fails on any `:error`
  finding, so an SEO regression breaks the build the same way a broken test
  does.

  This is the CI half of `mix alplus.seo.audit`. Both call the same engine,
  so a page that passes locally passes here.
  """

  use AlplusWeb.ConnCase, async: true

  alias Alplus.Seo.Audit
  alias Alplus.OrgsFixtures

  setup do
    Alplus.Content.Seeds.run()

    user = OrgsFixtures.user_fixture()
    scope = OrgsFixtures.scope_fixture(%{user: user})
    {org, owner_scope} = OrgsFixtures.org_fixture(scope)
    OrgsFixtures.subscribed_fixture(org)
    OrgsFixtures.project_fixture(owner_scope, org)

    :ok
  end

  describe "the public site" do
    test "has no SEO errors on any public route", %{conn: conn} do
      findings = Audit.run(&fetch(conn, &1))
      errors = Enum.filter(findings, &(&1.severity == :error))

      assert errors == [], "SEO errors found:\n\n" <> Audit.format(errors)
    end

    test "audits every public route, including the stable first-party changelog", %{conn: conn} do
      # Guards against the audit silently passing because it found nothing
      # to check, which would make the test above meaningless.
      paths = Audit.public_paths()

      assert length(paths) >= 10
      assert "/" in paths
      assert "/pricing" in paths
      assert "/changelog" in paths

      pages = Enum.map(paths, &fetch(conn, &1))
      assert Enum.all?(pages, &(&1.status == 200))
    end
  end

  describe "the checks actually detect defects" do
    # Each case feeds the engine deliberately broken HTML. Without these, a
    # check that silently never fires would still make the suite green.

    test "detects a missing title" do
      findings = audit_fixture(%{"/" => page_html(title: nil)})
      assert_finding(findings, :missing_title)
    end

    test "detects a missing meta description" do
      findings = audit_fixture(%{"/" => page_html(description: nil)})
      assert_finding(findings, :missing_description)
    end

    test "detects a missing canonical" do
      findings = audit_fixture(%{"/" => page_html(canonical: nil)})
      assert_finding(findings, :missing_canonical)
    end

    test "detects a canonical pointing at another page" do
      findings = audit_fixture(%{"/" => page_html(canonical: "https://postdeploy.dev/pricing")})
      assert_finding(findings, :cross_canonical)
    end

    test "detects a relative canonical" do
      findings = audit_fixture(%{"/" => page_html(canonical: "/")})
      assert_finding(findings, :malformed_canonical)
    end

    test "detects a missing and a duplicated h1" do
      assert_finding(audit_fixture(%{"/" => page_html(h1_count: 0)}), :missing_h1)
      assert_finding(audit_fixture(%{"/" => page_html(h1_count: 2)}), :multiple_h1)
    end

    test "detects duplicate titles across pages" do
      findings =
        audit_fixture(%{
          "/" => page_html(title: "Same"),
          "/pricing" => page_html(path: "/pricing", title: "Same", link_to: "/")
        })

      assert_finding(findings, :duplicate_title)
    end

    test "detects invalid JSON-LD" do
      findings = audit_fixture(%{"/" => page_html(json_ld: "{not json")})
      assert_finding(findings, :invalid_json_ld)
    end

    test "detects JSON-LD without an @type" do
      findings = audit_fixture(%{"/" => page_html(json_ld: ~s({"@context":"x"}))})
      assert_finding(findings, :invalid_json_ld)
    end

    test "rejects a non-schema.org JSON-LD context" do
      json = ~s({"@context":"https://example.com","@type":"Thing"})
      assert_finding(audit_fixture(%{"/" => page_html(json_ld: json)}), :invalid_json_ld)
    end

    test "rejects an empty JSON-LD graph" do
      json = ~s({"@context":"https://schema.org","@graph":[]})
      assert_finding(audit_fixture(%{"/" => page_html(json_ld: json)}), :invalid_json_ld)
    end

    test "rejects a stable page with a noindex robots directive" do
      html = page_html(extra_head: ~s(<meta name="robots" content="index, noindex">))
      assert_finding(audit_fixture(%{"/" => html}), :noindex_public_page)
    end

    test "requires visible FAQ questions and answers" do
      json =
        Jason.encode!(%{
          "@context" => "https://schema.org",
          "@type" => "FAQPage",
          "mainEntity" => [
            %{
              "@type" => "Question",
              "name" => "Invisible question",
              "acceptedAnswer" => %{"@type" => "Answer", "text" => "Invisible answer"}
            }
          ]
        })

      html = page_html(json_ld: json, extra_body: ~s(<section id="pricing-faq"></section>))
      assert_finding(audit_fixture(%{"/" => html}), :invisible_faq_schema)
    end

    test "requires visible breadcrumb items to match schema" do
      json =
        Jason.encode!(%{
          "@context" => "https://schema.org",
          "@type" => "BreadcrumbList",
          "itemListElement" => [
            %{
              "@type" => "ListItem",
              "position" => 1,
              "name" => "Wrong",
              "item" => "https://postdeploy.dev/"
            }
          ]
        })

      nav = ~s(<nav aria-label="Breadcrumb"><a href="/">Home</a></nav>)
      html = page_html(json_ld: json, extra_body: nav)
      assert_finding(audit_fixture(%{"/" => html}), :breadcrumb_schema_not_visible)
    end

    test "rejects an offer that is not visible" do
      json =
        Jason.encode!(%{
          "@context" => "https://schema.org",
          "@type" => "Offer",
          "name" => "Ghost monthly",
          "price" => "99"
        })

      assert_finding(audit_fixture(%{"/" => page_html(json_ld: json)}), :offer_schema_not_visible)
    end

    test "requires visible article authors and dates" do
      json =
        Jason.encode!(%{
          "@context" => "https://schema.org",
          "@type" => "TechArticle",
          "author" => %{"@type" => "Person", "name" => "Invisible Author"},
          "datePublished" => "2026-08-31"
        })

      assert_finding(
        audit_fixture(%{"/" => page_html(json_ld: json)}),
        :article_schema_not_visible
      )
    end

    test "detects conflicting properties for one JSON-LD entity id" do
      first =
        page_html(
          json_ld:
            ~s({"@context":"https://schema.org","@id":"https://postdeploy.dev/#x","@type":"Thing","name":"One"})
        )

      second =
        page_html(
          path: "/pricing",
          json_ld:
            ~s({"@context":"https://schema.org","@id":"https://postdeploy.dev/#x","@type":"Thing","name":"Two"})
        )

      pages = [
        %{path: "/", status: 200, html: LazyHTML.from_document(first)},
        %{path: "/pricing", status: 200, html: LazyHTML.from_document(second)}
      ]

      assert_finding(Audit.structured_data_valid(pages), :conflicting_entity_properties)
    end

    test "compares sitemap locs with audited paths and rejects variants" do
      pages = [%{path: "/", status: 200, html: nil}, %{path: "/pricing", status: 200, html: nil}]

      xml =
        ~s(<urlset><url><loc>https://postdeploy.dev/</loc></url><url><loc>https://other.example/pricing</loc></url><url><loc>https://postdeploy.dev/extra/</loc></url></urlset>)

      findings = Audit.sitemap_covers_public_routes(pages, %{status: 200, body: xml})

      assert Enum.any?(findings, &(&1.check == :wrong_origin_sitemap_url))
      assert Enum.any?(findings, &(&1.check == :missing_from_sitemap and &1.path == "/pricing"))
      assert Enum.any?(findings, &(&1.check == :non_canonical_sitemap_url))
      assert Enum.any?(findings, &(&1.check == :extra_sitemap_url))
    end

    test "allows published changelog entry paths outside the stable route inventory" do
      pages = [%{path: "/changelog", status: 200, html: nil}]

      xml =
        ~s(<urlset><url><loc>https://postdeploy.dev/changelog</loc></url><url><loc>https://postdeploy.dev/changelog/release-1</loc></url></urlset>)

      refute Enum.any?(
               Audit.sitemap_covers_public_routes(pages, %{status: 200, body: xml}),
               &(&1.check == :extra_sitemap_url)
             )
    end

    test "run reads the fetched sitemap instead of rebuilding it from routes" do
      [missing | _] = Audit.public_paths()

      xml =
        Audit.public_paths()
        |> Enum.reject(&(&1 == missing))
        |> Enum.map_join("", &"<url><loc>https://postdeploy.dev#{&1}</loc></url>")

      findings = audit_fixture(%{"/sitemap.xml" => "<urlset>#{xml}</urlset>"})
      assert Enum.any?(findings, &(&1.check == :missing_from_sitemap and &1.path == missing))
    end

    test "detects a broken internal link" do
      findings = audit_fixture(%{"/" => page_html(link_to: "/does-not-exist")})
      assert_finding(findings, :broken_internal_link)
    end

    test "detects an image without alt text" do
      findings = audit_fixture(%{"/" => page_html(img: "<img src=\"/a.png\">")})
      assert_finding(findings, :missing_alt_text)
    end

    test "accepts an image with alt text" do
      findings = audit_fixture(%{"/" => page_html(img: "<img src=\"/a.png\" alt=\"A\">")})
      refute Enum.any?(findings, &(&1.check == :missing_alt_text))
    end

    test "detects a non-200 public route" do
      findings = audit_fixture(%{"/" => {500, page_html()}})
      assert_finding(findings, :page_responds)
    end
  end

  describe "the accessibility checks detect real defects" do
    # Static analysis cannot replace a manual pass (contrast, focus order
    # and screen-reader behaviour need a browser and a person), but it does
    # catch the regressions that ship silently in a template edit.

    test "detects a missing and a duplicated main landmark" do
      assert_finding(audit_fixture(%{"/" => page_html(main: 0)}), :missing_main_landmark)
      assert_finding(audit_fixture(%{"/" => page_html(main: 2)}), :multiple_main_landmarks)
    end

    test "detects a missing lang attribute" do
      assert_finding(audit_fixture(%{"/" => page_html(lang: nil)}), :missing_lang)
    end

    test "detects a link with no discernible text" do
      findings = audit_fixture(%{"/" => page_html(extra_body: ~s(<a href="/pricing"></a>))})
      assert_finding(findings, :link_without_text)
    end

    test "accepts an icon link labelled with aria-label" do
      findings =
        audit_fixture(%{
          "/" => page_html(extra_body: ~s(<a href="/pricing" aria-label="Pricing"></a>))
        })

      refute Enum.any?(findings, &(&1.check == :link_without_text))
    end

    test "accepts an image link whose image has alt text" do
      findings =
        audit_fixture(%{
          "/" =>
            page_html(extra_body: ~s(<a href="/pricing"><img src="/a.png" alt="Pricing"></a>))
        })

      refute Enum.any?(findings, &(&1.check == :link_without_text))
    end

    test "detects a second unlabelled nav" do
      findings =
        audit_fixture(%{
          "/" =>
            page_html(
              extra_body: ~s(<nav aria-label="One"><a href="/pricing">a</a></nav><nav></nav>)
            )
        })

      assert_finding(findings, :unlabelled_nav)
    end

    test "ignores an aria-hidden nav, which is not in the accessibility tree" do
      findings =
        audit_fixture(%{
          "/" =>
            page_html(
              extra_body:
                ~s(<nav aria-label="One"><a href="/pricing">a</a></nav><nav aria-hidden="true"></nav>)
            )
        })

      refute Enum.any?(findings, &(&1.check == :unlabelled_nav))
    end

    test "warns when a heading level is skipped" do
      findings = audit_fixture(%{"/" => page_html(extra_body: "<h4>Skipped past h2</h4>")})

      assert Enum.any?(
               findings,
               &(&1.check == :skipped_heading_level and &1.severity == :warning)
             )
    end

    test "accepts a sequential heading order" do
      findings =
        audit_fixture(%{"/" => page_html(extra_body: "<h2>Two</h2><h3>Three</h3><h2>Two</h2>")})

      refute Enum.any?(findings, &(&1.check == :skipped_heading_level))
    end
  end

  describe "the inventory checks detect drift" do
    # `pages_are_in_the_inventory` and `inventory_has_no_dead_entries` are
    # gone: `Alplus.Seo.Inventory` now reads `cluster`/`intent`/
    # `primary_query` straight off each content row, and those attributes
    # are `allow_nil? false`, so a row cannot exist undeclared and the
    # inventory cannot list a row that does not exist. The remaining check,
    # cannibalisation, has a real failure mode a required attribute cannot
    # catch: two different rows can both set the same primary_query.

    test "reports no cannibalisation for the current inventory" do
      assert Audit.no_query_cannibalisation([]) == []
    end

    test "flags two rows that claim the same primary query" do
      {:ok, _a} =
        Alplus.Content.create_page(
          %{
            slug: "cannibal-a",
            path: "/cannibal-a",
            title: "Cannibal A",
            meta_description: "A page.",
            summary: "A page.",
            lastmod: ~D[2026-09-04],
            cluster: "other",
            intent: "informational",
            primary_query: "duplicate query for the cannibalisation test"
          },
          authorize?: false
        )

      {:ok, _b} =
        Alplus.Content.create_page(
          %{
            slug: "cannibal-b",
            path: "/cannibal-b",
            title: "Cannibal B",
            meta_description: "Another page.",
            summary: "Another page.",
            lastmod: ~D[2026-09-04],
            cluster: "other",
            intent: "informational",
            primary_query: "Duplicate Query For The Cannibalisation Test"
          },
          authorize?: false
        )

      findings = Audit.no_query_cannibalisation([])

      assert Enum.any?(findings, fn f ->
               f.check == :query_cannibalisation and f.path == "/cannibal-a"
             end)

      assert Enum.any?(findings, fn f ->
               f.check == :query_cannibalisation and f.path == "/cannibal-b"
             end)
    end
  end

  describe "the guide publish gate" do
    # SITE-ARCHITECTURE.md §8 condition 1: two pages in a reserved
    # programmatic set need 3+ materially different fields between them.
    test "names a near-duplicate pair of heartbeat guides" do
      shared = %{
        docs_host: "docs.example.com",
        platform_failure_mode: "Example silently stops running scheduled jobs.",
        sources: [
          %{
            "label" => "Example docs",
            "url" => "https://docs.example.com/x",
            "retrieved" => "2026-09-04"
          }
        ],
        not_offered: ["PostDeploy does not read Example's logs"],
        lastmod: ~D[2026-09-04],
        last_verified_on: ~D[2026-09-04],
        cluster: "cron"
      }

      {:ok, _a} =
        Alplus.Content.create_guide(
          Map.merge(shared, %{
            slug: "near-duplicate-a-heartbeat",
            path: "/guides/near-duplicate-a-heartbeat",
            title: "A heartbeat",
            meta_description: "Monitor A.",
            summary: "Monitor A.",
            platform: "Duplicate A",
            intent: "informational",
            primary_query: "test near duplicate a heartbeat query"
          }),
          authorize?: false
        )

      {:ok, _b} =
        Alplus.Content.create_guide(
          Map.merge(shared, %{
            slug: "near-duplicate-b-heartbeat",
            path: "/guides/near-duplicate-b-heartbeat",
            title: "B heartbeat",
            meta_description: "Monitor B.",
            summary: "Monitor B.",
            platform: "Duplicate B",
            intent: "informational",
            primary_query: "test near duplicate b heartbeat query"
          }),
          authorize?: false
        )

      findings = Audit.guide_publish_gate([])

      assert Enum.any?(findings, fn f ->
               f.check == :publish_gate_insufficient_differentiation and
                 f.path == "/guides/near-duplicate-a-heartbeat"
             end)

      assert Enum.any?(findings, fn f ->
               f.check == :publish_gate_insufficient_differentiation and
                 f.path == "/guides/near-duplicate-b-heartbeat"
             end)
    end

    test "keeps an earlier code verification valid after a prose-only page edit" do
      path = "/guides/prose-edited-heartbeat"

      {:ok, _guide} =
        Alplus.Content.create_guide(
          %{
            slug: "prose-edited-heartbeat",
            path: path,
            title: "Prose-edited heartbeat",
            meta_description: "A verified sample with newer supporting prose.",
            summary: "The sample remains unchanged after a prose edit.",
            platform: "Prose edit fixture",
            docs_host: "docs.prose-edit.example.com",
            platform_failure_mode: "The fixture can stop without a completed run.",
            sources: [
              %{
                "label" => "Fixture docs",
                "url" => "https://docs.prose-edit.example.com/schedules",
                "retrieved" => "2026-09-04"
              }
            ],
            not_offered: ["PostDeploy does not run the fixture task"],
            body_sections: [%{"heading" => "Sample", "code" => "echo verified"}],
            code_verified_on: ~D[2026-09-04],
            lastmod: ~D[2026-09-09],
            last_verified_on: ~D[2026-09-09],
            cluster: "cron",
            intent: "informational",
            primary_query: "prose edited heartbeat fixture"
          },
          authorize?: false
        )

      findings = Audit.guide_publish_gate([])

      refute Enum.any?(findings, fn finding ->
               finding.path == path and finding.check == :code_sample_not_verified
             end)
    end

    test "rejects a platform guide without a recorded code verification" do
      path = "/guides/unverified-heartbeat"

      {:ok, _guide} =
        Alplus.Content.create_guide(
          %{
            slug: "unverified-heartbeat",
            path: path,
            title: "Unverified heartbeat",
            meta_description: "A platform guide without a verified sample.",
            summary: "The sample has no recorded execution.",
            platform: "Unverified fixture",
            docs_host: "docs.unverified.example.com",
            platform_failure_mode: "The fixture can stop without a completed run.",
            sources: [
              %{
                "label" => "Fixture docs",
                "url" => "https://docs.unverified.example.com/schedules",
                "retrieved" => "2026-09-04"
              }
            ],
            not_offered: ["PostDeploy does not run the fixture task"],
            body_sections: [%{"heading" => "Sample", "code" => "echo unverified"}],
            lastmod: ~D[2026-09-09],
            last_verified_on: ~D[2026-09-09],
            cluster: "cron",
            intent: "informational",
            primary_query: "unverified heartbeat fixture"
          },
          authorize?: false
        )

      findings = Audit.guide_publish_gate([])

      assert Enum.any?(findings, fn finding ->
               finding.path == path and finding.check == :code_sample_not_verified
             end)
    end

    test "the seeded heartbeat guides pass the publish gate" do
      findings =
        Audit.guide_publish_gate([])
        |> Enum.filter(fn f ->
          f.path in [
            "/guides/github-actions-heartbeat",
            "/guides/kubernetes-cronjob-heartbeat",
            "/guides/heroku-scheduler-heartbeat",
            "/guides/systemd-timer-heartbeat",
            "/guides/laravel-scheduler-heartbeat",
            "/guides/airflow-heartbeat",
            "/guides/gitlab-ci-schedule-heartbeat"
          ]
        end)

      assert findings == []
    end
  end

  describe "the social preview checks detect missing metadata" do
    # A shared link with no image renders as a bare text card, which is the
    # difference between a click and a scroll past.

    test "detects a missing og:image" do
      assert_finding(audit_fixture(%{"/" => page_html(og_image: nil)}), :missing_og_image)
    end

    test "detects a missing twitter card" do
      assert_finding(audit_fixture(%{"/" => page_html(twitter_card: nil)}), :missing_twitter_card)
    end

    test "detects a relative og:image, which crawlers will not resolve" do
      findings = audit_fixture(%{"/" => page_html(og_image: "/images/og-default.png")})
      assert_finding(findings, :relative_og_image)
    end

    test "accepts an absolute og:image" do
      findings =
        audit_fixture(%{"/" => page_html(og_image: "https://postdeploy.dev/images/x.png")})

      refute Enum.any?(findings, &(&1.check == :relative_og_image))
    end
  end

  describe "the canonical-URL checks detect duplicates" do
    test "flags a page published at a non-canonical URL" do
      findings = Audit.urls_are_canonical([%{path: "/monitoring/", status: 200, html: nil}])

      assert Enum.any?(findings, &(&1.check == :non_canonical_path and &1.severity == :error))
    end

    test "warns about an internal link to a URL variant" do
      # A link to a variant costs a redirect hop on the way to the page it
      # meant, and leaks signal at that hop.
      findings =
        audit_fixture(%{"/" => page_html(extra_body: ~s(<a href="/pricing/">Pricing</a>))})

      assert Enum.any?(findings, &(&1.check == :link_to_url_variant))
    end

    test "does not flag a link to the root" do
      findings = audit_fixture(%{"/" => page_html(extra_body: ~s(<a href="/">Home</a>))})

      refute Enum.any?(findings, &(&1.check == :link_to_url_variant))
    end
  end

  # -- helpers ----------------------------------------------------------

  defp fetch(conn, path) do
    response = get(conn, path)
    %{status: response.status, body: response.resp_body}
  end

  # Runs the engine over hand-written HTML. Paths not supplied fall back to a
  # valid page, so each test isolates exactly one defect.
  defp audit_fixture(pages) do
    Audit.run(fn path ->
      case Map.get(pages, path) do
        nil when path == "/sitemap.xml" ->
          %{status: 200, body: sitemap_xml()}

        nil ->
          %{status: 200, body: page_html(path: path, title: "Title for #{path}")}

        {status, body} ->
          %{status: status, body: body}

        body ->
          %{status: 200, body: body}
      end
    end)
  end

  defp sitemap_xml do
    urls =
      Audit.public_paths()
      |> Enum.map_join("", &"<url><loc>https://postdeploy.dev#{&1}</loc></url>")

    ~s(<?xml version="1.0"?><urlset>#{urls}</urlset>)
  end

  defp page_html(opts \\ []) do
    path = Keyword.get(opts, :path, "/")
    title = Keyword.get(opts, :title, "A valid unique title for #{path}")
    canonical = Keyword.get(opts, :canonical, "https://postdeploy.dev" <> path)
    h1_count = Keyword.get(opts, :h1_count, 1)
    img = Keyword.get(opts, :img, "")
    json_ld = Keyword.get(opts, :json_ld, ~s({"@context":"https://schema.org","@type":"Thing"}))
    lang = Keyword.get(opts, :lang, "en")
    main_count = Keyword.get(opts, :main, 1)
    extra_body = Keyword.get(opts, :extra_body, "")
    extra_head = Keyword.get(opts, :extra_head, "")
    og_image = Keyword.get(opts, :og_image, "https://postdeploy.dev/images/og-default.png")
    twitter_card = Keyword.get(opts, :twitter_card, "summary_large_image")

    description =
      Keyword.get(
        opts,
        :description,
        "A meta description for #{path} that is comfortably long enough to pass the minimum length check."
      )

    # Every fixture links to all seeded paths so the orphan and sitemap
    # checks stay quiet unless a test is specifically about them.
    links =
      case Keyword.get(opts, :link_to) do
        nil -> Enum.map_join(Audit.public_paths(), "", &~s(<a href="#{&1}">l</a>))
        href -> ~s(<a href="#{href}">l</a>)
      end

    body = """
    #{String.duplicate("<h1>Heading</h1>", h1_count)}
    #{img}#{links}#{extra_body}
    """

    """
    <!DOCTYPE html><html#{if lang, do: ~s( lang="#{lang}"), else: ""}><head>
    #{if title, do: "<title>#{title}</title>", else: ""}
    #{if description, do: ~s(<meta name="description" content="#{description}">), else: ""}
    #{if canonical, do: ~s(<link rel="canonical" href="#{canonical}">), else: ""}
    #{if title, do: ~s(<meta property="og:title" content="#{title}">), else: ""}
    #{if og_image, do: ~s(<meta property="og:image" content="#{og_image}">), else: ""}
    #{if twitter_card, do: ~s(<meta name="twitter:card" content="#{twitter_card}">), else: ""}
    #{extra_head}#{if json_ld, do: ~s(<script type="application/ld+json">#{json_ld}</script>), else: ""}
    </head><body>
    #{String.duplicate("<main>#{body}</main>", main_count)}
    #{if main_count == 0, do: body, else: ""}
    </body></html>
    """
  end

  defp assert_finding(findings, check) do
    assert Enum.any?(findings, &(&1.check == check and &1.severity == :error)),
           "expected an error finding #{inspect(check)}, got: #{inspect(Enum.map(findings, & &1.check))}"
  end
end
