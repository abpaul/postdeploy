defmodule AlplusWeb.ChangelogControllerTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Changelog
  alias Alplus.PublicPages
  alias Alplus.Scope
  alias Alplus.Status
  alias Alplus.Status.RateLimiter

  @source_url "https://private.example/source-secret"
  @actor_email "changelog-actor@example.com"
  @public_slug "public-updates"

  setup do
    user = user_fixture(%{email: @actor_email})
    {org, owner_scope} = org_fixture(Scope.for_user(user.id))
    project = project_fixture(owner_scope, org, %{name: "Public changelog project"})
    scope = Scope.put_project(owner_scope, project.id)

    {:ok, changelog} =
      Changelog.create_changelog(
        %{
          org_id: org.id,
          project_id: project.id,
          public_title: "Public updates",
          public_slug: @public_slug
        },
        actor: scope
      )

    {:ok, identity} = PublicPages.get_for_project(scope, project.id)
    {:ok, _published_identity} = PublicPages.publish(scope, identity)

    %{org: org, project: project, scope: scope, changelog: changelog}
  end

  test "HTML lists only published entries", context do
    published = publish_entry(context, "Published HTML update")
    _draft = draft_entry(context, "Draft HTML update")
    archived = publish_entry(context, "Archived HTML update")
    assert {:ok, _archived} = Changelog.archive_entry(archived, actor: context.scope)

    conn = get(build_conn(), "/status/#{@public_slug}/changelog")
    assert conn.status == 200

    html = response(conn, 200)
    assert html =~ ~s(id="public-page-navigation")
    assert html =~ ~s(id="public-page-changelog-link")
    assert html =~ ~s(aria-current="page")
    assert html =~ ~r{<a href="/status/#{@public_slug}/changelog\.rss"[^>]*min-h-target-min}
    assert html =~ ~r{<a href="/status/#{@public_slug}/changelog\.json"[^>]*min-h-target-min}

    entries =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#changelog-entries")
      |> LazyHTML.to_html()

    assert entries =~ published.title
    refute entries =~ "Draft HTML update"
    refute entries =~ "Archived HTML update"
  end

  test "customer changelog pages never load PostDeploy's first-party tracker", context do
    previous = Application.get_env(:alplus, :measure_self_token)
    Application.put_env(:alplus, :measure_self_token, "msr_postdeploy_self")
    on_exit(fn -> Application.put_env(:alplus, :measure_self_token, previous) end)
    entry = publish_entry(context, "Customer tracker boundary")

    for path <- [
          "/status/#{@public_slug}/changelog",
          "/status/#{@public_slug}/changelog/#{entry.public_slug}"
        ] do
      html = build_conn() |> get(path) |> response(200)
      refute html =~ "/m.js"
    end
  end

  test "filters area and version before pagination and exposes all filters", context do
    _matching =
      publish_entry(context, "Filtered observe update", %{area: "observe", version: "2.4.0"})

    for index <- 1..24 do
      publish_entry(context, "Filtered monitor update #{index}", %{
        area: "monitor",
        version: "2.3.0"
      })
    end

    conn = get(build_conn(), "/status/#{@public_slug}/changelog?area=observe&version=2.4.0")
    assert conn.status == 200

    html = response(conn, 200)
    assert html =~ "Filtered observe update"
    refute html =~ "Filtered monitor update"
    assert html =~ ~s|name="version"|
    assert html =~ ~s|name="year"|
    assert html =~ ~s|value="2.4.0"|
  end

  test "a filtered changelog with no matches offers to clear filters", context do
    _published = publish_entry(context, "Monitor update", %{area: "monitor"})

    conn = get(build_conn(), "/status/#{@public_slug}/changelog?area=measure")
    assert conn.status == 200

    document = conn |> response(200) |> LazyHTML.from_document()
    filtered_empty = LazyHTML.query(document, "#changelog-filtered-empty")

    assert Enum.count(filtered_empty) == 1
    assert LazyHTML.text(filtered_empty) =~ "No updates match these filters."
    assert document |> LazyHTML.query("#changelog-empty") |> Enum.count() == 0

    assert document |> LazyHTML.query("#changelog-postdeploy-action") |> Enum.count() == 0

    assert document
           |> LazyHTML.query("#changelog-filtered-empty-clear")
           |> LazyHTML.attribute("href") == ["/status/#{@public_slug}/changelog"]
  end

  test "rate-limits every public Changelog format with retry headers", context do
    {:ok, identity} = PublicPages.get_for_project(context.scope, context.project.id)

    for _request <- 1..120 do
      assert :ok = RateLimiter.check(identity.id)
    end

    conn = get(build_conn(), "/status/#{@public_slug}/changelog.json")
    assert conn.status == 429
    assert [retry_after] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry_after) > 0
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert response(conn, 429) == "Too Many Requests"
  end

  test "RSS lists only published entries", context do
    published = publish_entry(context, "Published RSS update")
    _draft = draft_entry(context, "Draft RSS update")
    archived = publish_entry(context, "Archived RSS update")
    assert {:ok, _archived} = Changelog.archive_entry(archived, actor: context.scope)

    conn = get(build_conn(), "/status/#{@public_slug}/changelog.rss")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/rss+xml"]
    assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
    rss = response(conn, 200)
    assert {_document, _rest} = :xmerl_scan.string(String.to_charlist(rss))

    assert rss =~
             "<link>#{AlplusWeb.Endpoint.url()}/status/#{@public_slug}/changelog</link>"

    assert rss =~ ~r{<link>https?://[^<]+</link>}
    assert rss =~ ~r{<guid isPermaLink="true">https?://[^<]+</guid>}

    assert rss =~
             ~r|<pubDate>[A-Z][a-z]{2}, [0-9]{2} [A-Z][a-z]{2} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} GMT</pubDate>|

    refute rss =~ ~r{<guid isPermaLink="true">/}

    rss_items =
      rss
      |> LazyHTML.from_document()
      |> LazyHTML.query("item")
      |> LazyHTML.to_html()

    assert rss_items =~ published.title
    refute rss_items =~ "Draft RSS update"
    refute rss_items =~ "Archived RSS update"
  end

  test "JSON lists only published entries and keeps its stable shape", context do
    published = publish_entry(context, "Published JSON update")
    _draft = draft_entry(context, "Draft JSON update")
    archived = publish_entry(context, "Archived JSON update")
    assert {:ok, _archived} = Changelog.archive_entry(archived, actor: context.scope)

    conn = get(build_conn(), "/status/#{@public_slug}/changelog.json")
    assert conn.status == 200
    assert ["application/json" <> _charset] = get_resp_header(conn, "content-type")
    assert get_resp_header(conn, "x-robots-tag") == ["noindex"]

    payload = json_response(conn, 200)
    assert payload["title"] == "Public updates"
    assert payload["slug"] == @public_slug
    assert Map.keys(payload) |> Enum.sort() == ["entries", "slug", "title"]

    assert [
             %{
               "html" => _html,
               "published_at" => _published_at,
               "slug" => published_slug,
               "title" => "Published JSON update"
             }
           ] = payload["entries"]

    assert published_slug == published.public_slug
    refute response(conn, 200) =~ "Draft JSON update"
    refute response(conn, 200) =~ "Archived JSON update"
  end

  test "public formats contain no internal, actor, source, revision, or audit data", context do
    published = publish_entry(context, "Public data boundary")
    {:ok, [revision]} = Changelog.list_revisions(published, actor: context.scope)

    bodies = [
      response(get(build_conn(), "/status/#{@public_slug}/changelog"), 200),
      response(get(build_conn(), "/status/#{@public_slug}/changelog.rss"), 200),
      response(get(build_conn(), "/status/#{@public_slug}/changelog.json"), 200)
    ]

    for body <- bodies do
      refute body =~ published.id
      refute body =~ revision.id
      refute body =~ context.org.id
      refute body =~ context.project.id
      refute body =~ published.grant_id
      refute body =~ published.external_id
      refute body =~ @actor_email
      refute body =~ @source_url
      refute body =~ "revision"
      refute body =~ "audit"
      refute body =~ "request_metadata"
      refute body =~ "correlation_id"
      refute body =~ "evidence_ids"
      refute body =~ "inserted_at"
      refute body =~ "updated_at"
    end
  end

  test "an unknown entry slug ending in .json stays a 404", _context do
    path = "/status/#{@public_slug}/changelog/never-existed.json"

    assert %{plug: AlplusWeb.ChangelogController, plug_opts: :project_entry, path_params: params} =
             Phoenix.Router.route_info(AlplusWeb.Router, "GET", path, %{})

    assert params["entry_slug"] == "never-existed.json"
    assert_error_sent 404, fn -> get(build_conn(), path) end
  end

  test "legacy HTML and frozen entry URLs permanently redirect", context do
    published = publish_entry(context, "Legacy redirect update")

    legacy = get(build_conn(), "/changelog/#{@public_slug}")

    assert legacy.status == 301
    assert redirected_to(legacy, 301) == "/status/#{@public_slug}/changelog"

    legacy_entry =
      get(build_conn(), "/changelog/#{@public_slug}/entries/#{published.public_slug}")

    assert legacy_entry.status == 301

    assert redirected_to(legacy_entry, 301) ==
             "/status/#{@public_slug}/changelog/#{published.public_slug}"
  end

  test "legacy RSS and JSON feeds retain their fields, links, and ordering", context do
    older = publish_entry(context, "Older legacy feed update")
    newer = publish_entry(context, "Newer legacy feed update")

    rss =
      build_conn()
      |> get("/changelog/#{@public_slug}.rss")
      |> response(200)

    assert rss =~ "<link>#{AlplusWeb.Endpoint.url()}/changelog/#{@public_slug}</link>"

    assert rss =~
             "<link>#{AlplusWeb.Endpoint.url()}/changelog/#{@public_slug}/entries/#{newer.public_slug}</link>"

    assert :binary.match(rss, newer.title) |> elem(0) < :binary.match(rss, older.title) |> elem(0)

    json_conn = get(build_conn(), "/changelog/#{@public_slug}.json")
    assert json_conn.status == 200

    payload = json_response(json_conn, 200)
    assert Map.keys(payload) |> Enum.sort() == ["entries", "slug", "title"]
    assert payload["slug"] == @public_slug
    assert payload["title"] == "Public updates"

    assert Enum.map(payload["entries"], & &1["slug"]) == [newer.public_slug, older.public_slug]
  end

  test "status-owned pages preserve legacy Changelog HTML, entry, RSS, and JSON URLs", context do
    status_context = status_wins_context(context)
    published = publish_entry(status_context, "Status-owned legacy update")

    legacy = get(build_conn(), "/changelog/changelog-legacy")
    assert legacy.status == 301
    assert redirected_to(legacy, 301) == "/status/status-canonical/changelog"

    legacy_entry =
      get(build_conn(), "/changelog/changelog-legacy/entries/#{published.public_slug}")

    assert legacy_entry.status == 301

    assert redirected_to(legacy_entry, 301) ==
             "/status/status-canonical/changelog/#{published.public_slug}"

    legacy_rss = get(build_conn(), "/changelog/changelog-legacy.rss")
    assert legacy_rss.status == 200
    assert response(legacy_rss, 200) =~ "Status-owned legacy update"
    assert response(legacy_rss, 200) =~ "/changelog/changelog-legacy"

    legacy_json = get(build_conn(), "/changelog/changelog-legacy.json")
    assert legacy_json.status == 200
    assert json_response(legacy_json, 200)["entries"] |> length() == 1
  end

  test "a Status alias is not accepted as a legacy Changelog slug", context do
    status_context = status_wins_context(context)
    {:ok, identity} = PublicPages.get_for_project(status_context.scope, status_context.project.id)

    assert :ok =
             PublicPages.reserve_alias(
               status_context.scope,
               identity,
               "status-only",
               "status",
               nil
             )

    assert_error_sent 404, fn -> get(build_conn(), "/changelog/status-only") end
  end

  test "a published Changelog with no published entries shows an honest empty state", context do
    published = publish_entry(context, "Temporary update")
    assert {:ok, _archived} = Changelog.archive_entry(published, actor: context.scope)

    conn = get(build_conn(), "/status/#{@public_slug}/changelog")
    assert conn.status == 200

    document = conn |> response(200) |> LazyHTML.from_document()

    assert document |> LazyHTML.query("#changelog-empty") |> Enum.count() == 1
    assert document |> LazyHTML.query("#changelog-entries") |> Enum.count() == 0
    refute response(conn, 200) =~ "Temporary update"
  end

  test "a valid changelog slug renders HTML", context do
    custom = custom_changelog_context(context, "release-rss", "RSS changelog")
    _published = publish_entry(custom, "RSS update")

    conn = get(build_conn(), "/status/release-rss/changelog")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
    assert response(conn, 200) =~ "RSS update"
  end

  test "public HTML renders configured title and logo", context do
    assert {:ok, _} =
             Changelog.update_settings(
               context.changelog,
               %{logo_url: "https://cdn.example.test/logo.svg"},
               actor: context.scope
             )

    _published = publish_entry(context, "Branded update")
    conn = get(build_conn(), "/status/#{@public_slug}/changelog")

    assert response(conn, 200) =~ "Public updates"
    assert response(conn, 200) =~ "https://cdn.example.test/logo.svg"
  end

  test "the stream page renders one scannable list of linked posts", context do
    assert {:ok, _} =
             Changelog.update_settings(
               context.changelog,
               %{logo_url: "https://cdn.example.test/logo.svg"},
               actor: context.scope
             )

    older = publish_entry(context, "Older structural update")
    newer = publish_entry(context, "Newer structural update")

    document =
      build_conn()
      |> get("/status/#{@public_slug}/changelog")
      |> response(200)
      |> LazyHTML.from_document()

    assert document |> LazyHTML.query("h1") |> Enum.count() == 1
    assert document |> LazyHTML.query("h1#changelog-title") |> Enum.count() == 1

    header_logos =
      LazyHTML.query(document, "#changelog-header img[src='https://cdn.example.test/logo.svg']")

    assert Enum.count(header_logos) == 1

    assert document |> LazyHTML.query("#changelog-summary") |> Enum.count() == 0
    assert document |> LazyHTML.query("#changelog-formats") |> Enum.count() == 0

    for format <- ["rss", "json"] do
      assert document
             |> LazyHTML.query("a[href='/changelog/#{@public_slug}.#{format}']")
             |> Enum.count() == 0
    end

    rows = LazyHTML.query(document, "#changelog-entries a[data-permalink]")

    assert LazyHTML.attribute(rows, "id") == [
             "changelog-entry-#{newer.public_slug}",
             "changelog-entry-#{older.public_slug}"
           ]

    for entry <- [newer, older] do
      permalink = "/status/#{@public_slug}/changelog/#{entry.public_slug}"
      row = "#changelog-entry-#{entry.public_slug}"

      assert document |> LazyHTML.query(row) |> LazyHTML.attribute("href") == [permalink]
      assert document |> LazyHTML.query("#{row} h2") |> Enum.count() == 1
      assert document |> LazyHTML.query("#{row} time[datetime]") |> Enum.count() == 1

      # The whole row is the link, so a nested anchor would be invalid markup
      # and would compete with it.
      assert document |> LazyHTML.query("#{row} a") |> Enum.count() == 0
    end

    assert document |> LazyHTML.query("#changelog-empty") |> Enum.count() == 0
  end

  test "a list row teases the opening paragraph and leaves the rest to the entry page", context do
    {:ok, entry} =
      Changelog.upsert_draft(
        %{
          project_id: context.project.id,
          grant_id: Alplus.Id.generate(:mcp_oauth_grant),
          external_id: "external-teaser",
          markdown:
            "---\ntitle: Teaser update\n---\nThe [release notes](https://example.test/notes) land today.\n\nSecond paragraph stays on the entry page.\n\n## A heading stays too",
          sources: [%{kind: "release", url: @source_url, label: "Private source"}]
        },
        actor: context.scope
      )

    {:ok, published} = Changelog.publish_entry(entry, 1, actor: context.scope)
    row = "#changelog-entry-#{published.public_slug}"

    document =
      build_conn()
      |> get("/status/#{@public_slug}/changelog")
      |> response(200)
      |> LazyHTML.from_document()

    teaser = document |> LazyHTML.query("#{row} p") |> LazyHTML.text()

    # The anchor text survives; the anchor itself does not, so the row keeps one link.
    assert teaser =~ "The release notes land today."
    refute teaser =~ "Second paragraph"

    list = document |> LazyHTML.query("#changelog-entries") |> LazyHTML.to_html()

    refute list =~ "Second paragraph stays on the entry page."
    refute list =~ "A heading stays too"
    refute list =~ "https://example.test/notes"

    # The entry page still serves the whole document.
    body =
      build_conn()
      |> get("/status/#{@public_slug}/changelog/#{published.public_slug}")
      |> response(200)

    assert body =~ "Second paragraph stays on the entry page."
    assert body =~ "A heading stays too"
  end

  test "an entry that opens with a heading teases its first paragraph", context do
    {:ok, entry} =
      Changelog.upsert_draft(
        %{
          project_id: context.project.id,
          grant_id: Alplus.Id.generate(:mcp_oauth_grant),
          external_id: "external-heading-first",
          markdown:
            "---\ntitle: Heading first\n---\n## Read this before you upgrade\n\nThe signature header changed name.",
          sources: [%{kind: "release", url: @source_url, label: "Private source"}]
        },
        actor: context.scope
      )

    {:ok, published} = Changelog.publish_entry(entry, 1, actor: context.scope)

    teaser =
      build_conn()
      |> get("/status/#{@public_slug}/changelog")
      |> response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("#changelog-entry-#{published.public_slug} p")
      |> LazyHTML.text()

    assert teaser =~ "The signature header changed name."
    refute teaser =~ "Read this before you upgrade"
  end

  test "the entry detail carries the back link and one reading surface", context do
    published = publish_entry(context, "Detail structural update")

    document =
      build_conn()
      |> get("/status/#{@public_slug}/changelog/#{published.public_slug}")
      |> response(200)
      |> LazyHTML.from_document()

    assert document |> LazyHTML.query("h1") |> Enum.count() == 1
    assert document |> LazyHTML.query("h1#changelog-entry-title") |> Enum.count() == 1

    back_links =
      LazyHTML.query(
        document,
        "#changelog-back-link[href='/status/#{@public_slug}/changelog']"
      )

    assert Enum.count(back_links) == 1

    assert document |> LazyHTML.query("#changelog-entry-body") |> Enum.count() == 1

    assert document
           |> LazyHTML.query("#public-changelog-entry article time[datetime]")
           |> Enum.count() == 1
  end

  test "a changelog slug with a hyphen renders HTML", context do
    custom = custom_changelog_context(context, "release-v2", "Versioned changelog")
    _published = publish_entry(custom, "Versioned update")

    conn = get(build_conn(), "/status/release-v2/changelog")

    assert conn.status == 200
    assert response(conn, 200) =~ "Versioned update"
  end

  test "public responses carry the shared short cache policy", context do
    _published = publish_entry(context, "Cacheable update")

    for path <- [
          "/status/#{@public_slug}/changelog",
          "/status/#{@public_slug}/changelog.rss",
          "/status/#{@public_slug}/changelog.json"
        ] do
      conn = get(build_conn(), path)

      assert get_resp_header(conn, "cache-control") == [
               "public, max-age=30, stale-while-revalidate=60, stale-if-error=86400"
             ]
    end
  end

  test "archived entries return 404 and tombstoned entries return 410", context do
    archived = publish_entry(context, "Archived boundary")
    assert {:ok, _archived} = Changelog.archive_entry(archived, actor: context.scope)

    deleted = publish_entry(context, "Deleted boundary")

    assert :ok =
             Changelog.delete_permanently(deleted,
               actor: context.scope,
               grant_id: deleted.grant_id,
               correlation_id: "controller-test"
             )

    assert_error_sent 404, fn ->
      get(build_conn(), "/status/#{@public_slug}/changelog/#{archived.public_slug}")
    end

    deleted_conn =
      get(build_conn(), "/status/#{@public_slug}/changelog/#{deleted.public_slug}")

    assert deleted_conn.status == 410
    cache_control = get_resp_header(deleted_conn, "cache-control") |> List.first()
    refute cache_control =~ "public"
    refute cache_control =~ "31536000"
  end

  test "unknown slugs stay 404 and entry paths keep their suffixes", _context do
    assert_error_sent 404, fn -> get(build_conn(), "/changelog/never-existed") end

    assert_error_sent 404, fn ->
      get(build_conn(), "/status/#{@public_slug}/changelog/never-existed.rss")
    end
  end

  test "unpublished and never-published public pages return 404", context do
    assert {:ok, identity} = PublicPages.get_for_project(context.scope, context.project.id)
    assert {:ok, _unpublished} = PublicPages.unpublish(context.scope, identity)

    assert_error_sent 404, fn -> get(build_conn(), "/status/#{@public_slug}/changelog") end

    empty_project =
      project_fixture(context.scope, context.org, %{name: "Empty changelog project"})

    empty_scope = Scope.put_project(context.scope, empty_project.id)

    assert {:ok, _empty} =
             Changelog.create_changelog(
               %{
                 org_id: context.org.id,
                 project_id: empty_project.id,
                 public_title: "Empty updates",
                 public_slug: "empty-updates"
               },
               actor: empty_scope
             )

    assert_error_sent 404, fn -> get(build_conn(), "/status/empty-updates/changelog") end
  end

  test "PostDeploy's marketing changelog route renders the vendor row and contextual action",
       context do
    vendor = vendor_changelog_context(context)
    published = publish_entry(vendor, "PostDeploy update")

    for {path, action_id} <- [
          {"/changelog", "changelog-postdeploy-action"},
          {"/changelog/#{published.public_slug}", "changelog-entry-postdeploy-action"}
        ] do
      document = build_conn() |> get(path) |> response(200) |> LazyHTML.from_document()
      action = "##{action_id}"

      assert document |> LazyHTML.query(action) |> Enum.count() == 1

      assert document
             |> LazyHTML.query("#{action} a[href='/register']")
             |> Enum.count() == 1
    end
  end

  test "the marketing route renders a designed empty state without a published vendor entry",
       context do
    _vendor = vendor_changelog_context(context)

    conn = get(build_conn(), "/changelog")
    assert conn.status == 200

    document = conn |> response(200) |> LazyHTML.from_document()

    assert document |> LazyHTML.query("#changelog-empty") |> Enum.count() == 1
    assert document |> LazyHTML.query("h1#changelog-title") |> Enum.count() == 1
    assert document |> LazyHTML.query("#public-changelog article") |> Enum.count() == 0
    assert document |> LazyHTML.query("#changelog-formats") |> Enum.count() == 0
    assert document |> LazyHTML.query("#changelog-summary") |> Enum.count() == 0
  end

  # The route resolves the vendor changelog by its flag, never by a slug, so give
  # the vendor a different slug and let a tenant hold `postdeploy`. That is a
  # stronger claim than the original test made: it proves the slug cannot select
  # what /changelog serves, rather than only that this one slug cannot.
  #
  # The original test gave both changelogs the slug `postdeploy`, which the
  # global unique index now refuses outright. Two defences stack here: a tenant
  # cannot take the vendor's slug, and holding any slug wins nothing.
  test "the marketing route ignores a tenant holding the postdeploy slug", context do
    vendor = vendor_changelog_context(context, "vendor-updates")
    _published = publish_entry(vendor, "Vendor update")
    tenant = custom_changelog_context(context, "postdeploy", "Tenant changelog")
    _attacker = publish_entry(tenant, "Tenant takeover")

    conn = get(build_conn(), "/changelog")

    assert conn.status == 200
    assert response(conn, 200) =~ "Vendor update"
    refute response(conn, 200) =~ "Tenant takeover"

    # The tenant still owns its own public page, which is the point: it is a
    # normal customer changelog, it is simply not the vendor's.
    tenant_conn = get(build_conn(), "/status/postdeploy/changelog")
    assert tenant_conn.status == 200
    assert response(tenant_conn, 200) =~ "Tenant takeover"
  end

  defp vendor_changelog_context(context, public_slug \\ "postdeploy") do
    project =
      project_fixture(context.scope, context.org, %{
        name: "PostDeploy vendor project"
      })

    scope = Scope.put_project(context.scope, project.id)

    {:ok, _existing} =
      Changelog.create_changelog(
        %{
          org_id: context.org.id,
          project_id: project.id,
          public_title: "PostDeploy Changelog",
          public_slug: public_slug
        },
        actor: scope
      )

    {:ok, changelog} = Changelog.designate_vendor_by_public_token(project.public_token)
    {:ok, identity} = PublicPages.get_for_project(scope, project.id)
    {:ok, _published_identity} = PublicPages.publish(scope, identity)

    %{context | project: project, scope: scope, changelog: changelog}
  end

  defp publish_entry(context, title, metadata \\ %{}) do
    entry = draft_entry(context, title, metadata)
    {:ok, published} = Changelog.publish_entry(entry, 1, actor: context.scope)
    published
  end

  defp draft_entry(context, title, metadata \\ %{}) do
    front_matter =
      ["---", "title: #{title}"] ++
        Enum.map(metadata, fn {key, value} -> "#{key}: #{value}" end) ++ ["---", "Published body"]

    {:ok, entry} =
      Changelog.upsert_draft(
        %{
          project_id: context.project.id,
          grant_id: Alplus.Id.generate(:mcp_oauth_grant),
          external_id: "external-#{System.unique_integer([:positive])}",
          markdown: Enum.join(front_matter, "\n"),
          sources: [%{kind: "release", url: @source_url, label: "Private source"}]
        },
        actor: context.scope
      )

    entry
  end

  defp custom_changelog_context(context, public_slug, public_title) do
    project =
      project_fixture(context.scope, context.org, %{
        name: "#{public_title} project"
      })

    scope = Scope.put_project(context.scope, project.id)

    {:ok, changelog} =
      Changelog.create_changelog(
        %{
          org_id: context.org.id,
          project_id: project.id,
          public_title: public_title,
          public_slug: public_slug
        },
        actor: scope
      )

    {:ok, identity} = PublicPages.get_for_project(scope, project.id)
    {:ok, _published_identity} = PublicPages.publish(scope, identity)

    %{context | project: project, scope: scope, changelog: changelog}
  end

  defp status_wins_context(context) do
    project = project_fixture(context.scope, context.org, %{name: "Status-owned project"})
    scope = Scope.put_project(context.scope, project.id)

    assert {:ok, _status_page} =
             Status.create_page(scope, %{
               org_id: context.org.id,
               project_id: project.id,
               status_slug: "status-canonical",
               title: "Status canonical"
             })

    assert {:ok, changelog} =
             Changelog.create_changelog(
               %{
                 org_id: context.org.id,
                 project_id: project.id,
                 public_slug: "changelog-legacy",
                 public_title: "Changelog legacy",
                 enabled: true
               },
               actor: scope
             )

    assert {:ok, identity} = PublicPages.get_for_project(scope, project.id)
    assert identity.public_slug == "status-canonical"
    assert {:ok, _identity} = PublicPages.publish(scope, identity)

    %{context | project: project, scope: scope, changelog: changelog}
  end
end
