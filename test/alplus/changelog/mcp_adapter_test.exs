defmodule Alplus.Changelog.McpAdapterTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Audit.AuditLog
  alias Alplus.Changelog
  alias Alplus.Changelog.{Entry, SourceReference}
  alias Alplus.Mcp.{Cursor, Dispatch, Error, Principal}
  alias Alplus.PublicPages

  @read_tools [
    "changelog.get_settings",
    "changelog.list_entries",
    "changelog.get_entry",
    "changelog.list_revisions",
    "changelog.get_revision",
    "changelog.preview_entry"
  ]

  @mutation_tools [
    "changelog.upsert_draft",
    "changelog.publish_entry",
    "changelog.archive_entry",
    "changelog.restore_entry",
    "changelog.delete_entry"
  ]

  setup do
    user = user_fixture()
    user_scope = scope_fixture(%{user: user})
    {org, owner_scope} = org_fixture(user_scope)

    project =
      project_fixture(owner_scope, org, %{slug: "changelog-#{System.unique_integer([:positive])}"})

    owner_scope = Alplus.Scope.put_project(owner_scope, project.id)
    changelog = changelog_fixture(owner_scope, org, project)

    {:ok,
     %{
       org: org,
       project: project,
       changelog: changelog,
       owner_scope: owner_scope,
       principal: principal(owner_scope, :read_write)
     }}
  end

  test "feeds the projects.list handle directly into a changelog tool", context do
    assert {:ok, %{projects: [%{handle: handle}]}} =
             Dispatch.call("projects.list", %{}, context.principal)

    assert {:ok,
            %{settings: %{public_slug: "changelog", public_url: "/status/changelog/changelog"}}} =
             Dispatch.call(
               "changelog.get_settings",
               %{"project_handle" => handle},
               context.principal
             )
  end

  test "reaches every tool with read-write access and matches each output schema", context do
    entry = draft!(context, "all-tools", "---\ntitle: All tools\n---\nBody")
    revision = current_revision!(entry, context.owner_scope)

    calls = [
      {"changelog.get_settings", %{"project_handle" => context.project.id}, :settings},
      {"changelog.list_entries", %{"project_handle" => context.project.id}, :entries},
      {"changelog.get_entry",
       %{"project_handle" => context.project.id, "entry_handle" => entry.id}, :entry},
      {"changelog.list_revisions",
       %{"project_handle" => context.project.id, "entry_handle" => entry.id}, :revisions},
      {"changelog.get_revision",
       %{"project_handle" => context.project.id, "revision_handle" => revision.id}, :revision},
      {"changelog.preview_entry",
       %{"project_handle" => context.project.id, "entry_handle" => entry.id}, :html},
      {"changelog.upsert_draft",
       draft_args(context, "all-tools", "---\ntitle: All tools\n---\nBody", "all-tools-key"),
       :entry}
    ]

    Enum.each(calls, fn {tool, args, key} ->
      assert {:ok, result} = Dispatch.call(tool, args, context.principal)
      assert Map.has_key?(result, key)
      assert_output_schema(tool, result)
    end)

    assert {:ok, %{entry: %{status: :published} = published}} =
             publish!(context, entry, revision.revision_number, "publish-all-tools")

    Enum.each(
      [
        {"changelog.archive_entry", "archive-all-tools"},
        {"changelog.restore_entry", "restore-all-tools"},
        {"changelog.delete_entry", "delete-all-tools"}
      ],
      fn {tool, key} ->
        args = %{
          "project_handle" => context.project.id,
          "entry_handle" => published.handle,
          "idempotency_key" => key
        }

        assert {:ok, result} = Dispatch.call(tool, args, context.principal)
        assert_output_schema(tool, result)
      end
    )
  end

  test "revises an existing entry after grant rotation by handle", context do
    entry = draft!(context, "rotated", "---\ntitle: Original\n---\nBody")
    entry_id = entry.id
    revision = current_revision!(entry, context.owner_scope)

    assert {:ok, %{entry: %{status: :published}}} =
             publish!(context, entry, revision.revision_number, "publish-rotated")

    replacement = %{context.principal | grant_id: Alplus.Id.generate(:mcp_oauth_grant)}

    revised_args =
      draft_args(context, "rotated", "---\ntitle: Revised\n---\nBody", "revise-rotated")
      |> Map.put("entry_handle", entry.id)

    assert {:ok, %{entry: %{handle: ^entry_id}}} =
             Dispatch.call("changelog.upsert_draft", revised_args, replacement)

    own_args =
      draft_args(context, "rotated", "---\ntitle: Own copy\n---\nBody", "own-rotated")

    assert {:ok, %{entry: %{handle: own_handle}}} =
             Dispatch.call("changelog.upsert_draft", own_args, replacement)

    assert own_handle != entry.id
  end

  test "allows six reads for read-only access and refuses five mutations", context do
    entry = draft!(context, "read-only", "---\ntitle: Read only\n---\nBody")
    revision = current_revision!(entry, context.owner_scope)
    principal = %{context.principal | access: :read, scopes: ["changelog:read", "projects:read"]}

    read_args = %{
      "changelog.get_settings" => %{"project_handle" => context.project.id},
      "changelog.list_entries" => %{"project_handle" => context.project.id},
      "changelog.get_entry" => %{
        "project_handle" => context.project.id,
        "entry_handle" => entry.id
      },
      "changelog.list_revisions" => %{
        "project_handle" => context.project.id,
        "entry_handle" => entry.id
      },
      "changelog.get_revision" => %{
        "project_handle" => context.project.id,
        "revision_handle" => revision.id
      },
      "changelog.preview_entry" => %{
        "project_handle" => context.project.id,
        "entry_handle" => entry.id
      }
    }

    Enum.each(@read_tools, fn tool ->
      assert {:ok, _result} = Dispatch.call(tool, Map.fetch!(read_args, tool), principal)
    end)

    Enum.each(@mutation_tools, fn tool ->
      args = %{"project_handle" => context.project.id, "idempotency_key" => "read-only-#{tool}"}

      assert {:error,
              %Error{code: :insufficient_scope, details: %{required_scopes: ["changelog:write"]}}} =
               Dispatch.call(tool, args, principal)
    end)
  end

  test "returns not_found for a project outside the organization", context do
    other_user = user_fixture()
    other_scope = scope_fixture(%{user: other_user})
    {other_org, other_owner_scope} = org_fixture(other_scope)
    other_project = project_fixture(other_owner_scope, other_org)

    assert {:error, %Error{code: :not_found}} =
             Dispatch.call(
               "changelog.get_settings",
               %{"project_handle" => other_project.id},
               context.principal
             )
  end

  test "explains how to bootstrap a missing changelog", context do
    project =
      project_fixture(context.owner_scope, context.org, %{
        slug: "missing-changelog-#{System.unique_integer([:positive])}"
      })

    assert {:error,
            %Error{
              code: :not_found,
              message: message,
              details: %{bootstrap_tool: "changelog.upsert_draft"} = details
            }} =
             Dispatch.call(
               "changelog.get_settings",
               %{"project_handle" => project.id},
               context.principal
             )

    assert message =~ "changelog"
    assert message =~ "changelog.upsert_draft"
    refute message =~ "resource"

    refute Map.has_key?(details, :content)
    refute Map.has_key?(details, :grant_id)
    refute Map.has_key?(details, :id)
    refute inspect(details) =~ project.id
  end

  test "scopes external IDs to each grant", context do
    admin_scope =
      member_fixture(context.owner_scope, context.org, user_fixture(), "admin")
      |> Alplus.Scope.put_project(context.project.id)

    admin_principal = principal(admin_scope, :read_write)
    markdown_a = "---\ntitle: Agent A\n---\nBody A"
    markdown_b = "---\ntitle: Agent B\n---\nBody B"

    assert {:ok, %{entry: entry_a}} =
             Dispatch.call(
               "changelog.upsert_draft",
               draft_args(context, "shared", markdown_a, "shared-a"),
               context.principal
             )

    assert {:ok, %{entry: entry_b}} =
             Dispatch.call(
               "changelog.upsert_draft",
               draft_args(context, "shared", markdown_b, "shared-b"),
               admin_principal
             )

    refute entry_a.handle == entry_b.handle
    refute context.principal.grant_id == admin_principal.grant_id
    assert String.starts_with?(context.principal.grant_id, "mcogr_")
    assert String.starts_with?(admin_principal.grant_id, "mcogr_")

    get_args = %{"project_handle" => context.project.id, "external_id" => "shared"}

    assert {:ok, %{entry: %{handle: handle_a, title: "Agent A"}}} =
             Dispatch.call("changelog.get_entry", get_args, context.principal)

    assert {:ok, %{entry: %{handle: handle_b, title: "Agent B"}}} =
             Dispatch.call("changelog.get_entry", get_args, admin_principal)

    assert handle_a == entry_a.handle
    assert handle_b == entry_b.handle

    assert {:ok, %{entry: %{title: "Agent A updated"}}} =
             Dispatch.call(
               "changelog.upsert_draft",
               draft_args(
                 context,
                 "shared",
                 "---\ntitle: Agent A updated\n---\nBody A updated",
                 "shared-a-update"
               ),
               context.principal
             )

    assert {:ok, %{entry: %{title: "Agent B"}}} =
             Dispatch.call("changelog.get_entry", get_args, admin_principal)
  end

  test "rejects an archived project handle", context do
    Ash.destroy!(context.project, action: :archive, actor: context.owner_scope)

    assert {:error, %Error{code: :not_found}} =
             Dispatch.call(
               "changelog.get_settings",
               %{"project_handle" => context.project.id},
               context.principal
             )
  end

  test "requires evidence before publish and accepts one source reference", context do
    entry = draft!(context, "evidence", "---\ntitle: Evidence\n---\nBody")
    revision = current_revision!(entry, context.owner_scope)
    remove_sources!(entry, context.owner_scope)

    assert {:error, %Error{code: :missing_evidence}} =
             Dispatch.call(
               "changelog.publish_entry",
               publish_args(context, entry, revision.revision_number, "missing-evidence"),
               context.principal
             )

    entry = draft!(context, "evidence-with-source", "---\ntitle: Evidence\n---\nBody")
    revision = current_revision!(entry, context.owner_scope)

    assert {:ok, %{entry: %{status: :published}}} =
             Dispatch.call(
               "changelog.publish_entry",
               publish_args(context, entry, revision.revision_number, "with-evidence"),
               context.principal
             )
  end

  test "rejects stale publication and returns the current revision", context do
    entry = draft!(context, "stale", "---\ntitle: Stale\n---\nBody")
    revision = current_revision!(entry, context.owner_scope)

    assert {:error, %Error{code: :stale_revision, details: %{current_revision: current}}} =
             Dispatch.call(
               "changelog.publish_entry",
               publish_args(context, entry, revision.revision_number + 1, "stale-revision"),
               context.principal
             )

    assert current == revision.revision_number

    assert {:ok, %{entry: %{status: :published}}} =
             Dispatch.call(
               "changelog.publish_entry",
               publish_args(context, entry, revision.revision_number, "current-revision"),
               context.principal
             )
  end

  test "revises a published entry without taking the old public revision offline", context do
    entry = draft!(context, "revise", "---\ntitle: Original\n---\nOriginal body")
    revision = current_revision!(entry, context.owner_scope)

    assert {:ok, %{entry: published}} =
             publish!(context, entry, revision.revision_number, "revise-publish-1")

    public_slug = published.public_slug
    assert {:ok, %{html: old_html}} = Changelog.Public.entry("changelog", public_slug)

    revised_markdown = "---\ntitle: Revised\n---\nRevised body"

    assert {:ok, %{entry: revised}} =
             Dispatch.call(
               "changelog.upsert_draft",
               draft_args(context, "revise", revised_markdown, "revise-upsert"),
               context.principal
             )

    assert revised.public_slug == public_slug
    assert {:ok, %{html: ^old_html}} = Changelog.Public.entry("changelog", public_slug)

    revised_entry = Ash.get!(Entry, revised.handle, actor: context.owner_scope)
    current = current_revision!(revised_entry, context.owner_scope)
    assert current.status == :draft
    assert current.revision_number == revision.revision_number + 1

    assert {:ok, %{entry: republished}} =
             publish!(context, revised_entry, current.revision_number, "revise-publish-2")

    assert republished.public_slug == public_slug
    assert {:ok, %{html: new_html}} = Changelog.Public.entry("changelog", public_slug)
    refute new_html == old_html
  end

  test "maps invalid front matter and raw HTML to stable errors", context do
    assert {:error, %Error{code: :invalid_front_matter}} =
             Dispatch.call(
               "changelog.upsert_draft",
               draft_args(
                 context,
                 "invalid-front-matter",
                 "not front matter",
                 "invalid-front-matter-key"
               ),
               context.principal
             )

    assert {:error, %Error{code: :raw_html_forbidden}} =
             Dispatch.call(
               "changelog.upsert_draft",
               draft_args(
                 context,
                 "raw-html",
                 "---\ntitle: HTML\n---\n<div>unsafe</div>",
                 "raw-html-key"
               ),
               context.principal
             )
  end

  test "upsert_draft is idempotent and creates one entry", context do
    args =
      draft_args(context, "idempotent", "---\ntitle: Idempotent\n---\nBody", "idempotent-key")

    assert {:ok, first} = Dispatch.call("changelog.upsert_draft", args, context.principal)
    assert {:ok, second} = Dispatch.call("changelog.upsert_draft", args, context.principal)
    assert second == first

    assert {:ok, entries} =
             Changelog.list_entries(context.project.id, actor: context.owner_scope, limit: 100)

    assert Enum.count(entries, &(&1.external_id == "idempotent")) == 1

    conflicting =
      %{args | "markdown" => "---\ntitle: Changed\n---\nDifferent body"}

    assert {:error,
            %Error{
              code: :idempotency_key_conflict,
              details: %{resolution: "Use a new idempotency key for different arguments"}
            }} =
             Dispatch.call("changelog.upsert_draft", conflicting, context.principal)
  end

  test "publishes public metadata through MCP and renders it", context do
    markdown = """
    ---
    title: Safer releases
    summary: Smaller, safer deployments
    area: observe
    version: 2.4.0
    media_url: https://cdn.example.test/releases/safer.png
    media_alt: A safer release dashboard
    media_caption: Release health at a glance
    ---
    Body with **useful** details.
    """

    entry = draft!(context, "public-metadata", markdown)
    revision = current_revision!(entry, context.owner_scope)

    assert {:ok, %{entry: %{summary: "Smaller, safer deployments", area: "observe"} = published}} =
             publish!(context, entry, revision.revision_number, "publish-public-metadata")

    assert published.version == "2.4.0"
    assert published.media_url == "https://cdn.example.test/releases/safer.png"

    assert {:ok,
            %{
              title: "Safer releases",
              summary: "Smaller, safer deployments",
              area: "observe",
              version: "2.4.0",
              media_url: "https://cdn.example.test/releases/safer.png",
              media_alt: "A safer release dashboard",
              media_caption: "Release health at a glance",
              html: html
            }} = Changelog.Public.entry("changelog", published.public_slug)

    assert html =~ "<strong>useful</strong>"
  end

  test "reports which front matter rule failed", context do
    cases = [
      {"malformed_yaml", "not front matter"},
      {"unknown_key", "---\ntitle: Title\nauthor: Paul\n---\nBody"},
      {"duplicate_key", "---\ntitle: One\ntitle: Two\n---\nBody"},
      {"missing_title", "---\n{}\n---\nBody"},
      {"non_scalar_title", "---\ntitle:\n  - Nested\n---\nBody"}
    ]

    Enum.each(cases, fn {rule, markdown} ->
      assert {:error, %Error{code: :invalid_front_matter, details: %{rule: ^rule}}} =
               Dispatch.call(
                 "changelog.upsert_draft",
                 draft_args(context, "front-matter-#{rule}", markdown, "front-matter-#{rule}"),
                 context.principal
               )
    end)
  end

  test "allows deletion for an admin and refuses it for a plain member", context do
    entry = draft!(context, "delete-roles", "---\ntitle: Delete roles\n---\nBody")
    member_scope = member_fixture(context.owner_scope, context.org, user_fixture(), "member")

    args = %{
      "project_handle" => context.project.id,
      "entry_handle" => entry.id,
      "idempotency_key" => "member-delete"
    }

    assert {:error, %Error{code: :forbidden_role}} =
             Dispatch.call("changelog.delete_entry", args, principal(member_scope, :read_write))

    admin_scope = member_fixture(context.owner_scope, context.org, user_fixture(), "admin")

    assert {:ok, %{deleted: true}} =
             Dispatch.call(
               "changelog.delete_entry",
               %{args | "idempotency_key" => "admin-delete"},
               principal(admin_scope, :read_write)
             )

    # A direct domain read returns the bare atom. Only Dispatch wraps a failure
    # in Alplus.Mcp.Error, so assert the domain's own shape here.
    assert {:error, :not_found} = Changelog.get_entry(entry.id, actor: context.owner_scope)

    assert {:ok, audit_rows} = Ash.read(AuditLog, actor: admin_scope)

    assert Enum.any?(
             audit_rows,
             &(&1.action == "changelog.delete_entry" and &1.subject_id == entry.id and
                 &1.outcome == "allowed")
           )
  end

  test "rejects tampered and expired cursors with distinct codes", context do
    _first = draft!(context, "cursor-one", "---\ntitle: One\n---\nBody")
    _second = draft!(context, "cursor-two", "---\ntitle: Two\n---\nBody")

    assert {:error, %Error{code: :invalid_cursor}} =
             Dispatch.call(
               "changelog.list_entries",
               %{
                 "project_handle" => context.project.id,
                 "cursor" => "tampered-cursor",
                 "limit" => 1
               },
               context.principal
             )

    expired_cursor =
      Cursor.encode_at(
        context.principal,
        "changelog.list_entries",
        %{project_handle: context.project.id, status: nil},
        1,
        System.system_time(:second) - 86_401
      )

    assert {:error, %Error{code: :cursor_expired}} =
             Dispatch.call(
               "changelog.list_entries",
               %{
                 "project_handle" => context.project.id,
                 "cursor" => expired_cursor,
                 "limit" => 1
               },
               context.principal
             )
  end

  test "rejects invalid pagination limits instead of correcting them", context do
    for limit <- ["abc", 0, 101] do
      assert {:error,
              %Error{
                code: :invalid_argument,
                details: %{field: "limit", value: ^limit, minimum: 1, maximum: 100}
              }} =
               Dispatch.call(
                 "changelog.list_entries",
                 %{"project_handle" => context.project.id, "limit" => limit},
                 context.principal
               )
    end
  end

  test "redacts content, private URLs, internal ids, and raw Ash errors from failures", context do
    body = "---\nunknown: leaked\n---\nsecret markdown body"
    private_url = "https://private.example.test/source"

    args =
      put_in(draft_args(context, "redaction", body, "redaction-key")["sources"], [
        %{"kind" => "other", "url" => private_url}
      ])

    assert {:error, %Error{message: message, details: details} = error} =
             Dispatch.call("changelog.upsert_draft", args, context.principal)

    serialized = inspect({error, message, details})
    refute serialized =~ body
    refute serialized =~ private_url
    refute serialized =~ context.project.id
    refute serialized =~ "Ash.Error"
  end

  test "get_entry expresses its selector requirement via anyOf, not just required" do
    schema = Enum.find(Dispatch.tools(), &(&1.name == "changelog.get_entry")).input_schema

    assert schema.required == ["project_handle"]

    assert schema.anyOf == [
             %{required: ["entry_handle"]},
             %{required: ["external_id"]}
           ]
  end

  test "single-resource read tools declare no cursor or limit" do
    for tool <- [
          "changelog.get_settings",
          "changelog.get_entry",
          "changelog.get_revision",
          "changelog.preview_entry"
        ] do
      properties = Enum.find(Dispatch.tools(), &(&1.name == tool)).input_schema.properties
      refute Map.has_key?(properties, :cursor)
      refute Map.has_key?(properties, :limit)
    end
  end

  test "upsert_draft documents accepted source kinds as a schema enum" do
    schema = Enum.find(Dispatch.tools(), &(&1.name == "changelog.upsert_draft")).input_schema
    kind_schema = get_in(schema.properties, [:sources, :items, :properties, :kind])

    assert Enum.sort(kind_schema.enum) ==
             Enum.sort(~w(pull_request issue release deployment commit other))
  end

  test "the get_entry selector anyOf survives gateway discovery unaltered" do
    assert {:ok, %{"action" => %{"input_schema" => input_schema}}} =
             Alplus.Mcp.Gateway.call(
               "actions.get",
               %{"action" => "changelog.get_entry"},
               %Principal{access: :read_write}
             )

    assert input_schema["anyOf"] == [
             %{"required" => ["entry_handle"]},
             %{"required" => ["external_id"]}
           ]
  end

  defp changelog_fixture(scope, org, project) do
    {:ok, changelog} =
      Changelog.create_changelog(
        %{
          org_id: org.id,
          project_id: project.id,
          public_title: "Changelog",
          public_slug: "changelog"
        },
        actor: scope
      )

    {:ok, identity} = PublicPages.get_for_project(scope, project.id)
    {:ok, _published_identity} = PublicPages.publish(scope, identity)
    changelog
  end

  defp principal(scope, access) do
    scopes =
      case access do
        :read -> ["changelog:read", "projects:read"]
        :read_write -> ["changelog:read", "changelog:write", "projects:read"]
      end

    # An organization-scoped grant, which is the default MCP resource. These
    # tests reach several projects in one organization, and build principals
    # from bare organization scopes that carry no project.
    %Principal{
      grant_id: Alplus.Id.generate(:mcp_oauth_grant),
      org_id: scope.org_id,
      user_id: scope.user_id,
      access: access,
      source: :oauth,
      scope_mode: :organization,
      scopes: scopes,
      correlation_id: Alplus.Id.generate(:request)
    }
  end

  defp draft!(context, external_id, markdown) do
    {:ok, %{entry: entry}} =
      Dispatch.call(
        "changelog.upsert_draft",
        draft_args(context, external_id, markdown, "key-#{external_id}"),
        context.principal
      )

    Ash.get!(Entry, entry.handle, actor: context.owner_scope)
  end

  defp draft_args(context, external_id, markdown, idempotency_key),
    do: %{
      "project_handle" => context.project.id,
      "external_id" => external_id,
      "markdown" => markdown,
      "sources" => [%{"kind" => "other", "url" => "https://example.com/#{external_id}"}],
      "idempotency_key" => idempotency_key
    }

  defp current_revision!(entry, scope),
    do: elem(Changelog.list_revisions(entry, actor: scope, limit: 1), 1) |> List.first()

  defp publish!(context, entry, expected_revision, key),
    do:
      Dispatch.call(
        "changelog.publish_entry",
        publish_args(context, entry, expected_revision, key),
        context.principal
      )

  defp publish_args(context, entry, expected_revision, key),
    do: %{
      "project_handle" => context.project.id,
      "entry_handle" => entry.id,
      "expected_revision" => expected_revision,
      "idempotency_key" => key
    }

  defp remove_sources!(entry, scope) do
    {:ok, sources} =
      SourceReference
      |> Ash.Query.for_read(:for_entry, %{entry_id: entry.id}, actor: scope)
      |> Ash.read()

    Enum.each(sources, &Ash.destroy!(&1, actor: scope))
  end

  defp assert_output_schema(tool, result) do
    schema = Enum.find(Dispatch.tools(), &(&1.name == tool)).output_schema
    Enum.each(schema.required, fn key -> assert Map.has_key?(result, required_key(key)) end)
  end

  defp required_key("settings"), do: :settings
  defp required_key("entries"), do: :entries
  defp required_key("entry"), do: :entry
  defp required_key("revisions"), do: :revisions
  defp required_key("revision"), do: :revision
  defp required_key("html"), do: :html
  defp required_key("deleted"), do: :deleted
  defp required_key("next_cursor"), do: :next_cursor
end
