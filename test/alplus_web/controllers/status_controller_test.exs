defmodule AlplusWeb.StatusControllerTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Changelog
  alias Alplus.Monitoring.Monitor
  alias Alplus.Scope
  alias Alplus.Status

  setup do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)

    {:ok, page} =
      Status.create_page(scope, %{
        org_id: org.id,
        project_id: project.id,
        status_slug: "acme-status",
        title: "Acme status"
      })

    %{org: org, project: project, scope: scope, page: page}
  end

  test "public page renders component health without a session", context do
    create_linked_component(context)

    {:ok, _page} = Status.publish_page(context.scope, context.page)
    conn = get(build_conn(), "/status/acme-status")

    assert conn.status == 200
    html = response(conn, 200)
    assert html =~ "Acme status"
    assert html =~ "API"
    assert html =~ ~s(id="public-page-navigation")
    assert html =~ ~s(id="public-page-status-link")
    assert html =~ ~s(aria-current="page")
    assert html =~ ~r{<a href="/"[^>]*min-h-target-min}

    assert get_resp_header(conn, "cache-control") ==
             ["public, max-age=30, stale-while-revalidate=60, stale-if-error=86400"]

    refute conn.assigns[:current_user]
  end

  test "status show and history pages emit distinct SEO metadata", context do
    create_linked_component(context)
    {:ok, _page} = Status.publish_page(context.scope, context.page)

    show = response(get(build_conn(), "/status/acme-status"), 200)
    history = response(get(build_conn(), "/status/acme-status/history"), 200)

    assert show =~ ~r/<title[^>]*>Acme status<\/title>/

    assert show =~
             ~s|<meta name="description" content="Current status and service health for Acme status."|

    assert show =~ ~s|<link rel="canonical" href="https://postdeploy.dev/status/acme-status"|
    assert show =~ ~s|<meta property="og:title" content="Acme status"|

    assert show =~
             ~s|<meta property="og:description" content="Current status and service health for Acme status."|

    assert show =~ ~s|<meta property="og:url" content="https://postdeploy.dev/status/acme-status"|
    assert show =~ ~s|<meta name="twitter:title" content="Acme status"|

    assert show =~
             ~s|<meta name="twitter:description" content="Current status and service health for Acme status."|

    assert history =~ ~r/<title[^>]*>Acme status history<\/title>/

    assert history =~
             ~s|<meta name="description" content="90-day status history and incident timeline for Acme status."|

    assert history =~
             ~s|<link rel="canonical" href="https://postdeploy.dev/status/acme-status/history"|

    assert history =~ ~s|<meta property="og:title" content="Acme status history"|

    assert history =~
             ~s|<meta property="og:description" content="90-day status history and incident timeline for Acme status."|

    assert history =~
             ~s|<meta property="og:url" content="https://postdeploy.dev/status/acme-status/history"|

    assert history =~ ~s|<meta name="twitter:title" content="Acme status history"|

    assert history =~
             ~s|<meta name="twitter:description" content="90-day status history and incident timeline for Acme status."|
  end

  test "incident updates render on the public page, split active/past", context do
    create_linked_component(context)

    {:ok, _page} = Status.publish_page(context.scope, context.page)

    {:ok, open_incident} =
      Status.publish_incident(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
        title: "API outage",
        body: "We are investigating."
      })

    {:ok, _update} =
      Status.publish_incident_update(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_incident_id: open_incident.id,
        body: "Fix deployed, monitoring recovery."
      })

    {:ok, resolved_incident} =
      Status.publish_incident(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
        title: "Yesterday's blip",
        body: "Brief elevated latency."
      })

    {:ok, _closing_update} =
      Status.publish_incident_update(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_incident_id: resolved_incident.id,
        body: "Latency is back to normal."
      })

    {:ok, _resolved} = Status.resolve_incident(context.scope, resolved_incident)

    html = response(get(build_conn(), "/status/acme-status"), 200)
    document = LazyHTML.from_document(html)

    # The open incident and its update live in the active section.
    active = document |> LazyHTML.query("#status-active-incidents") |> LazyHTML.to_html()
    assert active =~ "API outage"
    assert active =~ "Fix deployed, monitoring recovery."
    assert active =~ "Latest update"

    # The current page answers "what is broken now": the resolved incident is
    # not on it. It lives on the history route with the message that closed it.
    refute html =~ "Yesterday&#39;s blip"

    history = response(get(build_conn(), "/status/acme-status/history"), 200)

    past =
      history
      |> LazyHTML.from_document()
      |> LazyHTML.query("#status-incident-history")
      |> LazyHTML.to_html()

    assert past =~ "Yesterday&#39;s blip"
    assert past =~ "Resolved"
    assert past =~ "Latency is back to normal."
    refute past =~ "API outage"

    # The LiveView hook refreshes the status content without replacing the page.
    assert html =~ ~s(data-refresh-seconds="30")
  end

  test "the public page surfaces recent Changelog entries", context do
    create_linked_component(context)
    {:ok, _page} = Status.publish_page(context.scope, context.page)

    {:ok, _changelog} =
      Changelog.create_changelog(
        %{
          org_id: context.org.id,
          project_id: context.project.id,
          public_title: "Acme updates",
          public_slug: "acme-status"
        },
        actor: context.scope
      )

    entry = publish_changelog_entry(context, "Faster API recovery")

    document =
      build_conn()
      |> get("/status/acme-status")
      |> response(200)
      |> LazyHTML.from_document()

    assert document |> LazyHTML.query("#status-changelog") |> Enum.count() == 1

    assert document
           |> LazyHTML.query(
             "#status-changelog a[href='/status/acme-status/changelog/#{entry.public_slug}']"
           )
           |> LazyHTML.text() =~ "Faster API recovery"

    assert document
           |> LazyHTML.query("#status-changelog a[href='/status/acme-status/changelog']")
           |> Enum.count() == 1
  end

  test "the five not-found cases use one public response", context do
    assert_error_sent 404, fn -> get(build_conn(), "/status/unknown") end
    assert_error_sent 404, fn -> get(build_conn(), "/status/acme-status") end

    assert {:error, :service_required} = Status.publish_page(context.scope, context.page)
    assert_error_sent 404, fn -> get(build_conn(), "/status/acme-status") end

    create_linked_component(context)
    assert {:ok, _published_with_components} = Status.publish_page(context.scope, context.page)

    assert get(build_conn(), "/status/acme-status").status == 200

    Alplus.Repo.query!("UPDATE organizations SET trial_ends_at = $1 WHERE id = $2", [
      DateTime.add(DateTime.utc_now(), -60, :second),
      context.org.id
    ])

    assert_error_sent 404, fn -> get(build_conn(), "/status/acme-status") end
  end

  test "embed framing is allowed only on the embed route", context do
    create_linked_component(context)

    {:ok, _page} = Status.publish_page(context.scope, context.page)
    page_conn = get(build_conn(), "/status/acme-status")
    embed_conn = get(build_conn(), "/status/acme-status/embed")
    json_conn = get(build_conn(), "/status/acme-status/embed.json")

    [page_csp] = get_resp_header(page_conn, "content-security-policy")
    [embed_csp] = get_resp_header(embed_conn, "content-security-policy")
    assert page_csp =~ "frame-ancestors 'none'"
    assert embed_csp =~ "frame-ancestors *"
    assert get_resp_header(embed_conn, "x-frame-options") == []
    assert json_conn.status == 200

    assert json_response(json_conn, 200) == %{
             "status" => "operational",
             "components" => [%{"name" => "API", "status" => "up"}]
           }
  end

  test "incident feed returns published narratives", context do
    create_linked_component(context)

    {:ok, page} = Status.publish_page(context.scope, context.page)

    {:ok, _announcement} =
      Status.publish_announcement(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: page.id,
        title: "Planned change",
        body: "A planned change is scheduled."
      })

    {:ok, _maintenance} =
      Status.schedule_maintenance(
        context.scope,
        %{
          org_id: context.org.id,
          project_id: context.project.id,
          status_page_id: page.id,
          title: "Database work",
          starts_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
          ends_at: DateTime.add(DateTime.utc_now(), 7_200, :second)
        },
        []
      )

    {:ok, _incident} =
      Status.publish_incident(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: page.id,
        title: "API outage",
        body: "We are investigating."
      })

    conn = get(build_conn(), "/status/acme-status/feed.xml")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/rss+xml"]
    assert response(conn, 200) =~ "<rss version=\"2.0\">"
    assert response(conn, 200) =~ "API outage"
    assert response(conn, 200) =~ "Planned change"
    assert response(conn, 200) =~ "Database work"
  end

  test "a legacy public slug redirects the status page and its related paths", context do
    create_linked_component(context)
    {:ok, _published} = Status.publish_page(context.scope, context.page)

    {:ok, identity} = Alplus.PublicPages.get_for_project(context.scope, context.project.id)

    assert {:ok, _updated} =
             Alplus.PublicPages.update(context.scope, identity, %{public_slug: "canonical-status"})

    for suffix <- ["", "/history", "/feed.xml", "/embed", "/embed.json"] do
      conn = get(build_conn(), "/status/acme-status#{suffix}")
      assert conn.status == 301
      assert redirected_to(conn, 301) == "/status/canonical-status#{suffix}"
    end

    assert get(build_conn(), "/status/canonical-status").status == 200
  end

  test "a Changelog alias is not accepted as a Status slug", context do
    assert {:ok, _changelog} =
             Changelog.create_changelog(
               %{
                 org_id: context.org.id,
                 project_id: context.project.id,
                 public_title: "Release notes",
                 public_slug: "changelog-only"
               },
               actor: context.scope
             )

    create_linked_component(context)
    assert {:ok, _published} = Status.publish_page(context.scope, context.page)

    assert_error_sent 404, fn -> get(build_conn(), "/status/changelog-only") end
  end

  test "public status and history expose accessible localized time controls", context do
    component = create_linked_component(context)

    {:ok, page} = Status.publish_page(context.scope, context.page)

    {:ok, _announcement} =
      Status.publish_announcement(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: page.id,
        title: "Planned change",
        body: "A planned change is scheduled."
      })

    {:ok, _incident} =
      Status.publish_incident(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: page.id,
        service_ids: [component.id],
        title: "API outage",
        body: "We are investigating."
      })

    page_html = response(get(build_conn(), "/status/acme-status"), 200)
    history_html = response(get(build_conn(), "/status/acme-status/history"), 200)

    assert page_html =~ ~s(id="status-page-summary")
    assert page_html =~ ~s(aria-live="polite")
    assert page_html =~ ~s(data-status-timezone-root)
    assert page_html =~ ~s(id="status-timezone-toggle")
    assert page_html =~ ~s(data-status-time=)
    assert page_html =~ "UTC"

    # The current route answers "what is broken now". History lives on its
    # own route, reached by one link.
    refute page_html =~ ~s(id="status-incident-history")
    refute page_html =~ ~s(id="status-announcement-history")
    refute page_html =~ ~s(id="status-maintenance-history")
    assert page_html =~ ~s(id="status-history-link")
    assert history_html =~ ~s(id="status-history")
    assert history_html =~ ~s(id="status-incident-history")
    assert history_html =~ ~s(id="status-maintenance-history")

    assert position!(page_html, "status-page-summary") <
             position!(page_html, "status-active-incidents")

    assert position!(page_html, "status-active-incidents") <
             position!(page_html, "status-components")

    assert position!(page_html, "status-components") <
             position!(page_html, "status-announcements")

    assert history_html =~ ~s(id="public-status-history")
    assert history_html =~ ~s(data-status-timezone-root)
    assert history_html =~ ~s(data-status-timezone-toggle)
    assert history_html =~ ~r{<a href="/"[^>]*min-h-target-min}
    # The square strip is decoration for a reader that cannot see it. It is
    # hidden from assistive technology; one summary sentence answers it, and
    # the captioned daily table sits behind the disclosure.
    refute history_html =~ ~s(role="img")

    assert history_html =~
             "Daily uptime for API, in percent, last 90 days, oldest first."

    assert history_html =~ ~s(id="status-announcement-history")
  end

  test "anonymous reads return 429 after the per-page limit", context do
    create_linked_component(context)

    {:ok, page} = Status.publish_page(context.scope, context.page)

    for _ <- 1..120 do
      assert :ok = Alplus.Status.RateLimiter.check(page.id)
    end

    conn = get(build_conn(), "/status/acme-status")
    assert conn.status == 429
    assert [retry_after] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry_after) >= 1
  end

  defp create_linked_component(context) do
    {:ok, component} =
      Status.create_component(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
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
    component
  end

  defp publish_changelog_entry(context, title) do
    {:ok, entry} =
      Changelog.upsert_draft(
        %{
          project_id: context.project.id,
          grant_id: Alplus.Id.generate(:mcp_oauth_grant),
          external_id: "status-page-#{System.unique_integer([:positive])}",
          markdown: "---\ntitle: #{title}\n---\nRecovery details now appear in one place.",
          sources: [
            %{kind: "release", url: "https://private.example/source", label: "Private source"}
          ]
        },
        actor: context.scope
      )

    {:ok, published} = Changelog.publish_entry(entry, 1, actor: context.scope)
    published
  end

  defp position!(html, id) do
    {position, _length} = :binary.match(html, ~s(id="#{id}"))
    position
  end
end
