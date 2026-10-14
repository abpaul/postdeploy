defmodule AlplusWeb.ChangelogPublicRedesignTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Changelog
  alias Alplus.Monitoring.Monitor
  alias Alplus.PublicPages
  alias Alplus.Scope
  alias Alplus.Status

  @public_slug "postdeploy-redesign"

  @source_url "https://private.example/source-secret"

  setup do
    user = user_fixture(%{email: "changelog-redesign@example.com"})
    {org, owner_scope} = org_fixture(Scope.for_user(user.id))
    project = project_fixture(owner_scope, org, %{name: "PostDeploy vendor project"})
    scope = Scope.put_project(owner_scope, project.id)

    {:ok, _changelog} =
      Changelog.create_changelog(
        %{
          org_id: org.id,
          project_id: project.id,
          public_title: "PostDeploy Changelog",
          public_slug: @public_slug
        },
        actor: scope
      )

    {:ok, changelog} = Changelog.designate_vendor_by_public_token(project.public_token)
    {:ok, identity} = PublicPages.get_for_project(scope, project.id)
    {:ok, _identity} = PublicPages.publish(scope, identity)

    %{org: org, scope: scope, project: project, changelog: changelog, identity: identity}
  end

  test "first-party index, entry, and feeds share the PostDeploy identity", context do
    entry = publish_entry(context, "PostDeploy redesign update")

    index = get(build_conn(), "/changelog")
    assert index.status == 200
    body = response(index, 200)

    assert body =~ "This changelog runs on"
    assert body =~ "Yours can too."
    refute body =~ "alplus.dev"
    assert body =~ ~s|rel="canonical" href="https://postdeploy.dev/changelog"|
    assert body =~ ~s|href="/changelog.rss"|
    assert body =~ ~r{<a href="/changelog\.rss"[^>]*min-h-target-min}
    assert body =~ ~s|href="/changelog.json"|
    assert body =~ ~r{<a href="/changelog\.json"[^>]*min-h-target-min}

    entry_conn = get(build_conn(), "/changelog/#{entry.public_slug}")
    assert entry_conn.status == 200
    assert response(entry_conn, 200) =~ entry.title

    assert response(entry_conn, 200) =~
             ~s|rel="canonical" href="https://postdeploy.dev/changelog/#{entry.public_slug}"|

    rss_conn = get(build_conn(), "/changelog.rss")
    assert rss_conn.status == 200
    assert get_resp_header(rss_conn, "x-robots-tag") == ["noindex"]

    assert response(rss_conn, 200) =~
             "#{AlplusWeb.Endpoint.url()}/changelog/#{entry.public_slug}"

    json_conn = get(build_conn(), "/changelog.json")
    assert json_conn.status == 200
    assert get_resp_header(json_conn, "x-robots-tag") == ["noindex"]
    assert [%{"slug" => slug}] = json_response(json_conn, 200)["entries"]
    assert slug == entry.public_slug
    sitemap = response(get(build_conn(), "/sitemap.xml"), 200)
    assert sitemap =~ "<loc>https://postdeploy.dev/changelog</loc>"
    assert sitemap =~ "<loc>https://postdeploy.dev/changelog/#{entry.public_slug}</loc>"
  end

  test "sitemap includes vendor entries beyond the public page size", context do
    entries =
      for index <- 1..25 do
        publish_entry(context, "PostDeploy sitemap update #{index}")
      end

    sitemap = response(get(build_conn(), "/sitemap.xml"), 200)

    for entry <- entries do
      assert sitemap =~ "<loc>https://postdeploy.dev/changelog/#{entry.public_slug}</loc>"
    end
  end

  test "filtered first-party changelog variants are noindex", %{conn: conn} do
    conn = get(conn, "/changelog?area=platform")
    assert conn.status == 200

    html = response(conn, 200)
    document = LazyHTML.from_document(html)

    assert LazyHTML.attribute(LazyHTML.query(document, ~s(meta[name="robots"])), "content") ==
             ["noindex"]

    assert html =~ ~s|<link rel="canonical" href="https://postdeploy.dev/changelog"|
  end

  test "the retired first-party slug redirects to the marketing identity", context do
    {:ok, identity} = PublicPages.get_for_project(context.scope, context.project.id)

    assert :ok =
             PublicPages.reserve_alias(
               context.scope,
               identity,
               "alplus-dev",
               "changelog",
               nil
             )

    conn = get(build_conn(), "/changelog/alplus-dev")
    assert conn.status == 301
    assert redirected_to(conn, 301) == "/changelog"
  end

  test "PostDeploy's hosted pages wear the lockup and keep the local reading chrome",
       context do
    entry = publish_entry(context, "PostDeploy hosted update")
    publish_status_page(context)

    for path <- [
          "/status/#{@public_slug}",
          "/status/#{@public_slug}/history",
          "/status/#{@public_slug}/changelog",
          "/status/#{@public_slug}/changelog/#{entry.public_slug}"
        ] do
      document = build_conn() |> get(path) |> response(200) |> LazyHTML.from_document()

      # Hosting PostDeploy's own project does not turn these reading surfaces
      # into the marketing site: the site topbar stays away and the local
      # Status/Changelog navigation stays.
      assert document |> LazyHTML.query("#marketing-header") |> Enum.empty?(),
             "marketing topbar on #{path}"

      assert document |> LazyHTML.query("#public-page-navigation") |> Enum.count() == 1

      lockup = LazyHTML.query(document, ~s(header a[href="/"][aria-label="PostDeploy home"]))
      assert Enum.count(lockup) == 1, "no PostDeploy lockup on #{path}"
      assert lockup |> LazyHTML.query("svg") |> Enum.count() == 1
      assert LazyHTML.text(lockup) =~ "postdeploy"

      # PostDeploy never credits itself with the attribution a customer page
      # carries.
      refute document |> LazyHTML.query("main") |> LazyHTML.text() =~ "Powered by"
    end

    marketing = build_conn() |> get("/changelog") |> response(200) |> LazyHTML.from_document()

    assert marketing |> LazyHTML.query("#marketing-header") |> Enum.count() == 1
    assert marketing |> LazyHTML.query("#public-page-navigation") |> Enum.empty?()
  end

  defp publish_status_page(context) do
    {:ok, page} =
      Status.create_page(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_slug: @public_slug,
        title: "PostDeploy Changelog"
      })

    {:ok, component} =
      Status.create_component(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: page.id,
        name: "API"
      })

    monitor =
      Ash.create!(
        Monitor,
        %{
          org_id: context.org.id,
          project_id: context.project.id,
          type: "http",
          name: "API monitor"
        },
        action: :create,
        actor: context.scope
      )

    Ash.Seed.update!(monitor, %{last_known_status: "up"})
    :ok = Status.link_monitor(context.scope, component, monitor.id)
    {:ok, published} = Status.publish_page(context.scope, page)
    published
  end

  defp publish_entry(context, title) do
    {:ok, entry} =
      Changelog.upsert_draft(
        %{
          project_id: context.project.id,
          grant_id: Alplus.Id.generate(:mcp_oauth_grant),
          external_id: "redesign-#{System.unique_integer([:positive])}",
          markdown: "---\ntitle: #{title}\n---\nPostDeploy release body",
          sources: [%{kind: "release", url: @source_url, label: "Private source"}]
        },
        actor: context.scope
      )

    {:ok, published} = Changelog.publish_entry(entry, 1, actor: context.scope)
    published
  end
end
