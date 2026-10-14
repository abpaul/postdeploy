defmodule AlplusWeb.PublicPagesDesignTest do
  @moduledoc """
  The public expression contract for the hosted Status page and Changelog.

  These pages use the same 1200px content width as the marketing site, with
  white surfaces on a 1px public hairline, pill controls with a 44px target,
  semantic tokens, and a captioned table behind every square strip.

  Identity on these pages follows ownership. PostDeploy's own hosted pages
  wear the marketing lockup; a customer's pages wear the customer's mark and
  never PostDeploy's.
  """

  use AlplusWeb.ConnCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Changelog
  alias Alplus.Monitoring.Monitor
  alias Alplus.PublicPages
  alias Alplus.Scope
  alias Alplus.Status

  @status_slug "design-status"
  @vendor_slug "design-postdeploy"

  # A raw colour in markup, either as an arbitrary value or as a stock
  # Tailwind palette step. Both are banned: only semantic tokens are allowed.
  @raw_hex ~r/\[#[0-9A-Fa-f]{3,8}\]/
  @stock_palette ~r/\b(?:bg|text|border|fill|stroke|decoration|divide|ring|from|via|to)-(?:slate|gray|zinc|neutral|stone|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose)-\d{2,3}\b/

  # Copy rule: no em dash, en dash, or middot used as a separator.
  @banned_separators ["—", "–", "·"]

  setup do
    user = user_fixture(%{email: "public-design@example.com"})
    {org, owner_scope} = org_fixture(Scope.for_user(user.id))
    project = project_fixture(owner_scope, org, %{name: "Acme"})
    scope = Scope.put_project(owner_scope, project.id)

    published_page(org, project, scope, @status_slug, "Acme status", "Acme changelog")

    vendor_project = project_fixture(owner_scope, org, %{name: "PostDeploy"})
    vendor_scope = Scope.put_project(owner_scope, vendor_project.id)

    published_page(
      org,
      vendor_project,
      vendor_scope,
      @vendor_slug,
      "PostDeploy status",
      "PostDeploy Changelog"
    )

    {:ok, _vendor} = Changelog.designate_vendor_by_public_token(vendor_project.public_token)

    %{
      org: org,
      project: project,
      scope: scope,
      vendor: %{org: org, project: vendor_project, scope: vendor_scope}
    }
  end

  describe "identity follows who owns the page" do
    test "PostDeploy's own hosted pages wear the marketing lockup", context do
      entry = publish_entry(context.vendor, "Vendor exports now stream")

      for path <- vendor_paths(entry) do
        header = path |> fetch() |> LazyHTML.query("header")

        # The same lockup the marketing header renders: the vector mark plus
        # the `postdeploy.` wordmark, linked home and named once.
        lockup = LazyHTML.query(header, ~s(a[href="/"][aria-label="PostDeploy home"]))
        assert Enum.count(lockup) == 1, "no PostDeploy lockup in #{path}"
        assert lockup |> LazyHTML.query("svg") |> Enum.count() == 1
        assert LazyHTML.text(lockup) =~ "postdeploy"

        # No image copy of the mark, and no neutral initial tile standing in
        # for a page that already has an owner.
        assert header |> LazyHTML.query("img") |> Enum.empty?(), "logo image in #{path}"
        assert header |> LazyHTML.query("#public-page-title") |> Enum.empty?()
      end
    end

    test "a customer's pages keep the customer's identity and never borrow PostDeploy's",
         context do
      entry = publish_entry(context, "Exports now stream")

      for path <- paths(entry) do
        header = path |> fetch() |> LazyHTML.query("header")
        text = LazyHTML.text(header)

        assert header |> LazyHTML.query("#public-page-title") |> Enum.count() == 1
        assert text =~ "Acme"
        refute text =~ "postdeploy", "PostDeploy wordmark on a customer page: #{path}"

        # No logo is configured, so the customer's own initial stands in. The
        # customer's name never links to PostDeploy.
        assert header |> LazyHTML.query(~s(a[href="/"])) |> Enum.empty?()
        assert header |> LazyHTML.query("svg") |> Enum.empty?()
        initial = LazyHTML.query(header, "span[class*='text-text-inverse']")
        assert initial |> LazyHTML.text() |> String.trim() == "A"
      end
    end

    test "a customer's own logo is used wherever they configured one", context do
      {:ok, identity} = PublicPages.get_for_project(context.scope, context.project.id)

      {:ok, _identity} =
        PublicPages.update(context.scope, identity, %{
          logo_url: "https://cdn.example.test/acme.svg"
        })

      entry = publish_entry(context, "Exports now stream")

      for path <- paths(entry) do
        logos =
          path
          |> fetch()
          |> LazyHTML.query(~s(header img[src="https://cdn.example.test/acme.svg"]))

        assert Enum.count(logos) == 1, "customer logo missing from #{path}"
        assert LazyHTML.attribute(logos, "alt") == [""]
      end
    end

    test "only a customer page carries the quiet product attribution", _context do
      for path <- [status_path(@status_slug), history_path(@status_slug)] do
        footer = path |> fetch() |> LazyHTML.query("main footer")

        assert LazyHTML.text(footer) =~ "Powered by"
        assert footer |> LazyHTML.query(~s(a[href="/"])) |> Enum.count() == 1

        # The registration promotion is gone: attribution is the only product
        # link a customer's status page carries.
        refute LazyHTML.text(footer) =~ "Create a status page"
        refute footer |> LazyHTML.query(~s(a[href="/register"])) |> Enum.any?()
      end

      for path <- [status_path(@vendor_slug), history_path(@vendor_slug)] do
        footer = path |> fetch() |> LazyHTML.query("main footer")

        refute LazyHTML.text(footer) =~ "Powered by"
      end
    end
  end

  describe "the status page speaks the public expression" do
    test "the verdict leads the page as one banner: a dot, a word, and one h1", context do
      document = fetch(status_path(@status_slug))

      assert document |> LazyHTML.query("main h1") |> Enum.count() == 1

      # The fixture's service has never been checked, so the verdict says so
      # instead of promising "all operational" on no evidence.
      verdict = LazyHTML.query(document, "h1#status-page-summary-verdict")
      assert LazyHTML.text(verdict) =~ "Operational, but API has no checks yet"
      assert LazyHTML.attribute(verdict, "aria-live") == ["polite"]

      summary = LazyHTML.query(document, "#status-page-summary")
      html = LazyHTML.to_html(summary)

      # State is a wash plus a dot plus the word, never colour alone.
      assert html =~ "bg-status-"
      assert html =~ "rounded-dot"
      assert LazyHTML.text(summary) =~ "Operational"
      assert summary |> LazyHTML.query("time[datetime]") |> Enum.count() == 1

      # The masthead names the project; the h1 answers the question.
      assert document |> LazyHTML.query("#public-page-header") |> LazyHTML.text() =~ "Acme status"

      _ = context
    end

    test "evidence uses the marketing content width and nothing floats", context do
      entry = publish_entry(context, "Exports now stream")

      for path <- paths(entry) ++ vendor_paths(publish_entry(context.vendor, "Vendor update")) do
        document = fetch(path)

        assert document |> LazyHTML.query("main [class*='shadow-frame']") |> Enum.empty?(),
               "a floating panel in #{path}"

        refute document |> LazyHTML.query("main [class*='max-w-content']") |> Enum.empty?(),
               "no marketing-width content in #{path}"
      end

      html = fetch_html(status_path(@status_slug))
      assert html =~ "rounded-frame border border-border-public"
      assert html =~ "bg-surface-raised"
    end

    test "the square strip is hidden, summarised once, and the daily table sits behind a disclosure",
         _context do
      document = fetch(status_path(@status_slug))
      row = LazyHTML.query(document, "#status-components article")

      refute LazyHTML.to_html(row) =~ ~s(role="img")

      strip = LazyHTML.query(row, "div[aria-hidden='true'] span[class*='rounded-tick']")
      refute Enum.empty?(strip)

      # One accessible summary per service, never a hidden 90-row table in
      # the resting tree: the daily record is inside the disclosure only.
      refute row |> LazyHTML.query("[id$='-summary']") |> LazyHTML.text() |> String.trim() == ""
      assert row |> LazyHTML.query(".sr-only table") |> Enum.empty?()
      assert row |> LazyHTML.query("details summary") |> LazyHTML.text() =~ "View daily uptime"

      caption = LazyHTML.query(row, "details table caption")

      assert LazyHTML.text(caption) =~
               "Daily uptime for API, in percent, last 90 days, oldest first."

      headers = row |> LazyHTML.query("details table thead th") |> LazyHTML.text()
      assert headers =~ "Day"
      assert headers =~ "Uptime (%)"
      assert headers =~ "State"
      assert headers =~ "Evidence"

      assert row |> LazyHTML.query("details table tbody tr") |> Enum.count() == 90
    end

    test "the 90 day history repeats the same contract", _context do
      document = fetch(history_path(@status_slug))

      assert document |> LazyHTML.query("main h1") |> Enum.count() == 1
      assert document |> LazyHTML.query("main h1") |> LazyHTML.text() =~ "90-day service history"
      refute LazyHTML.to_html(document) =~ ~s(role="img")

      assert document
             |> LazyHTML.query("#status-uptime details table caption")
             |> LazyHTML.text() =~
               "last 90 days"
    end
  end

  describe "the changelog speaks the same public expression" do
    test "the index is one consistent row feed under its title and filters", context do
      older = publish_entry(context, "Older structural update")
      newer = publish_entry(context, "Exports now stream")

      html = fetch_html(changelog_path(@status_slug))
      document = LazyHTML.from_document(html)

      assert document |> LazyHTML.query("main h1") |> Enum.count() == 1
      assert document |> LazyHTML.query("h1#changelog-title") |> Enum.count() == 1

      # Title, feeds and filters open the column, before the first row.
      assert position!(html, "changelog-title") < position!(html, "changelog-feeds")
      assert position!(html, "changelog-feeds") < position!(html, "changelog-filter-disclosure")
      assert position!(html, "changelog-filter-disclosure") < position!(html, "changelog-entries")

      rows = LazyHTML.query(document, "#changelog-entries a[data-permalink]")

      assert LazyHTML.attribute(rows, "id") == [
               "changelog-entry-#{newer.public_slug}",
               "changelog-entry-#{older.public_slug}"
             ]

      # Every published update is the same row: no lead card, and no second
      # call to action competing with the row's own link.
      refute html =~ "Read this update"

      for row <- rows do
        assert row |> LazyHTML.query("h2") |> Enum.count() == 1
        assert row |> LazyHTML.query("time[datetime]") |> Enum.count() == 1
        assert row |> LazyHTML.query("a a") |> Enum.empty?()
      end
    end

    test "an empty changelog reads as a plain state, not an empty hero", context do
      empty = published_changelog(context, "empty-changelog", "Empty updates")
      document = empty |> changelog_path() |> fetch()

      assert document |> LazyHTML.query("#changelog-entries") |> Enum.empty?()

      empty_state = LazyHTML.query(document, "#changelog-empty")
      assert Enum.count(empty_state) == 1
      assert LazyHTML.text(empty_state) =~ "No updates are published yet."
      refute LazyHTML.to_html(empty_state) =~ "border-dashed"
    end

    test "a filtered result stays distinct from an empty changelog", context do
      _entry = publish_entry(context, "Exports now stream")

      document = fetch(changelog_path(@status_slug) <> "?area=measure")

      assert document |> LazyHTML.query("#changelog-empty") |> Enum.empty?()

      filtered = LazyHTML.query(document, "#changelog-filtered-empty")
      assert LazyHTML.text(filtered) =~ "No updates match these filters."

      assert document
             |> LazyHTML.query("#changelog-filtered-empty-clear")
             |> LazyHTML.attribute("href") == [changelog_path(@status_slug)]
    end

    test "an entry page keeps one h1, a wide shell, and anchored readable body headings",
         context do
      entry = publish_entry(context, "Team roles for viewer and editor")
      _newer = publish_entry(context, "Exports now stream")
      document = fetch(entry_path(@status_slug, entry))

      assert document |> LazyHTML.query("main h1") |> Enum.count() == 1
      assert document |> LazyHTML.query("h1#changelog-entry-title") |> Enum.count() == 1
      assert LazyHTML.to_html(document) =~ "rounded-frame border border-border-public"

      # Every body H2 is addressable, so a section of an update can be linked.
      headings = LazyHTML.query(document, "#changelog-entry-body h2")
      refute Enum.empty?(headings)

      for id <- LazyHTML.attribute(headings, "id") do
        assert id =~ ~r/\A[a-z0-9-]+\z/
      end

      assert "section-what-changed" in LazyHTML.attribute(headings, "id")
    end
  end

  describe "shared rules on every public page" do
    test "markup names semantic tokens, never a raw colour", context do
      entry = publish_entry(context, "Exports now stream")
      vendor_entry = publish_entry(context.vendor, "Vendor update")

      for path <- paths(entry) ++ vendor_paths(vendor_entry) do
        html = fetch_html(path)

        for class <- Regex.scan(~r/class="([^"]*)"/, html, capture: :all_but_first) do
          [value] = class
          refute value =~ @raw_hex, "raw hex in #{path}: #{value}"
          refute value =~ @stock_palette, "stock palette in #{path}: #{value}"
        end
      end
    end

    test "copy uses no dash or middot as a separator", context do
      entry = publish_entry(context, "Exports now stream")
      vendor_entry = publish_entry(context.vendor, "Vendor update")

      for path <- paths(entry) ++ vendor_paths(vendor_entry) do
        text = path |> fetch() |> LazyHTML.query("main") |> LazyHTML.text()

        for separator <- @banned_separators do
          refute text =~ separator, "#{separator} in #{path}"
        end
      end
    end

    test "every public link carries the 44px target", context do
      entry = publish_entry(context, "Exports now stream")
      vendor_entry = publish_entry(context.vendor, "Vendor update")

      for path <- paths(entry) ++ vendor_paths(vendor_entry) do
        document = fetch(path)

        links =
          Enum.to_list(LazyHTML.query(document, "header a")) ++
            Enum.to_list(LazyHTML.query(document, "main a"))

        refute Enum.empty?(links)

        for link <- links do
          classes = link |> LazyHTML.attribute("class") |> List.first() |> to_string()
          permalink? = link |> LazyHTML.attribute("data-permalink") != []

          assert permalink? or classes =~ "min-h-target-min",
                 "small target in #{path}: #{LazyHTML.to_html(link)}"
        end
      end
    end

    test "navigation landmarks are named", context do
      entry = publish_entry(context, "Exports now stream")
      vendor_entry = publish_entry(context.vendor, "Vendor update")

      for path <- paths(entry) ++ vendor_paths(vendor_entry) do
        for nav <- path |> fetch() |> LazyHTML.query("nav") do
          assert nav |> LazyHTML.attribute("aria-label") != [],
                 "unnamed nav in #{path}: #{LazyHTML.to_html(nav)}"
        end
      end
    end

    test "the local navigation marks the page a visitor is on", context do
      entry = publish_entry(context, "Exports now stream")

      for {path, current} <- [
            {status_path(@status_slug), "public-page-status-link"},
            {history_path(@status_slug), "public-page-status-link"},
            {changelog_path(@status_slug), "public-page-changelog-link"},
            {entry_path(@status_slug, entry), "public-page-changelog-link"}
          ] do
        nav = path |> fetch() |> LazyHTML.query("#public-page-navigation")

        assert nav |> LazyHTML.query(~s([aria-current="page"])) |> LazyHTML.attribute("id") == [
                 current
               ]
      end
    end
  end

  defp paths(entry) do
    [
      status_path(@status_slug),
      history_path(@status_slug),
      changelog_path(@status_slug),
      entry_path(@status_slug, entry)
    ]
  end

  defp vendor_paths(entry) do
    [
      status_path(@vendor_slug),
      history_path(@vendor_slug),
      changelog_path(@vendor_slug),
      entry_path(@vendor_slug, entry)
    ]
  end

  defp status_path(slug), do: "/status/#{slug}"
  defp history_path(slug), do: "/status/#{slug}/history"
  defp changelog_path(slug), do: "/status/#{slug}/changelog"
  defp entry_path(slug, entry), do: "/status/#{slug}/changelog/#{entry.public_slug}"

  defp position!(html, id) do
    {index, _length} = :binary.match(html, ~s(id="#{id}"))
    index
  end

  defp fetch(path), do: path |> fetch_html() |> LazyHTML.from_document()

  defp fetch_html(path) do
    conn = get(build_conn(), path)
    assert conn.status == 200
    response(conn, 200)
  end

  # A published project page with one linked, never checked service, plus a
  # changelog on the same public identity.
  defp published_page(org, project, scope, slug, title, changelog_title) do
    {:ok, page} =
      Status.create_page(scope, %{
        org_id: org.id,
        project_id: project.id,
        status_slug: slug,
        title: title
      })

    {:ok, component} =
      Status.create_component(scope, %{
        org_id: org.id,
        project_id: project.id,
        status_page_id: page.id,
        name: "API"
      })

    monitor =
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "http", name: "API monitor"},
        action: :create,
        actor: scope
      )

    Ash.Seed.update!(monitor, %{last_known_status: "up"})
    :ok = Status.link_monitor(scope, component, monitor.id)
    {:ok, _published} = Status.publish_page(scope, page)

    {:ok, _changelog} =
      Changelog.create_changelog(
        %{
          org_id: org.id,
          project_id: project.id,
          public_title: changelog_title,
          public_slug: slug
        },
        actor: scope
      )

    {:ok, identity} = PublicPages.get_for_project(scope, project.id)
    {:ok, _identity} = PublicPages.publish(scope, identity)

    page
  end

  # A published public identity that carries a changelog and no status page.
  defp published_changelog(context, slug, title) do
    project = project_fixture(context.scope, context.org, %{name: title})
    scope = Scope.put_project(context.scope, project.id)

    {:ok, _changelog} =
      Changelog.create_changelog(
        %{
          org_id: context.org.id,
          project_id: project.id,
          public_title: title,
          public_slug: slug
        },
        actor: scope
      )

    {:ok, identity} = PublicPages.get_for_project(scope, project.id)
    {:ok, _identity} = PublicPages.publish(scope, identity)

    slug
  end

  defp publish_entry(context, title) do
    {:ok, entry} =
      Changelog.upsert_draft(
        %{
          project_id: context.project.id,
          grant_id: Alplus.Id.generate(:mcp_oauth_grant),
          external_id: "design-#{System.unique_integer([:positive])}",
          markdown:
            "---\ntitle: #{title}\n---\nReports over 50k rows used to fail at the gateway.\n\n## What changed\n\nThe gateway now streams them.",
          sources: [%{kind: "release", url: "https://private.example/source", label: "Source"}]
        },
        actor: context.scope
      )

    {:ok, published} = Changelog.publish_entry(entry, 1, actor: context.scope)
    published
  end
end
