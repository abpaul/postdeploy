defmodule Alplus.Changelog.DomainTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Changelog
  alias Alplus.Changelog.{ActivityEvent, SourceReference}
  alias Alplus.Mcp.IdempotencyRecord
  alias Alplus.PublicPages
  alias Alplus.Repo
  alias Alplus.Status
  require Ash.Query
  alias Alplus.Scope

  setup do
    scope = scope_fixture()
    {org, owner} = org_fixture(scope)
    project = project_fixture(owner, org)
    actor = Scope.put_project(owner, project.id)
    {:ok, org: org, owner: actor, project: project}
  end

  test "scopes every read by organization and project", %{
    org: org,
    owner: owner,
    project: project
  } do
    other_project = project_fixture(owner, org, %{name: "Other project"})
    other_actor = Scope.put_project(owner, other_project.id)
    {:ok, other_changelog} = changelog(other_project, other_actor, "other")
    {:ok, other_entry} = draft(other_project, other_changelog, other_actor, "other")
    {:ok, [other_revision]} = Changelog.list_revisions(other_entry, actor: other_actor)
    {:ok, [other_source]} = sources(other_entry, other_actor)
    assert {:error, :not_found} = Changelog.get_changelog(other_project.id, actor: owner)
    assert {:error, :not_found} = Changelog.get_entry(other_entry.id, actor: owner)
    assert {:error, :not_found} = Changelog.get_revision(other_revision.id, actor: owner)
    assert {:error, :not_found} = get_source(other_source.id, owner)

    foreign_scope = scope_fixture()
    {foreign_org, foreign_owner} = org_fixture(foreign_scope)
    foreign_project = project_fixture(foreign_owner, foreign_org)
    foreign_owner = Scope.put_project(foreign_owner, foreign_project.id)
    {:ok, foreign_changelog} = changelog(foreign_project, foreign_owner, "foreign")
    {:ok, foreign_entry} = draft(foreign_project, foreign_changelog, foreign_owner, "foreign")
    {:ok, [foreign_revision]} = Changelog.list_revisions(foreign_entry, actor: foreign_owner)
    {:ok, [foreign_source]} = sources(foreign_entry, foreign_owner)
    foreign_actor = Scope.put_project(owner, foreign_project.id)

    assert {:error, :not_found} =
             Changelog.get_changelog(foreign_project.id, actor: foreign_actor)

    assert {:error, :not_found} = Changelog.get_entry(foreign_entry.id, actor: foreign_actor)

    assert {:error, :not_found} =
             Changelog.get_revision(foreign_revision.id, actor: foreign_actor)

    assert {:error, :not_found} = get_source(foreign_source.id, foreign_actor)
    assert org.id == other_project.org_id
    assert project.id != other_project.id
  end

  test "members read content, while lifecycle and deletion require owner or admin",
       %{
         org: org,
         owner: owner,
         project: project
       } do
    member = member_fixture(owner, org, user_fixture(), "member") |> Scope.put_project(project.id)
    admin = member_fixture(owner, org, user_fixture(), "admin") |> Scope.put_project(project.id)
    {:ok, changelog} = changelog(project, owner, "roles")

    assert {:error, _} =
             Changelog.upsert_draft(
               %{
                 project_id: project.id,
                 grant_id: Alplus.Id.generate(:mcp_oauth_grant),
                 external_id: "new-member-entry",
                 markdown: "---\ntitle: denied\n---\n\nBody",
                 sources: []
               },
               actor: member
             )

    assert {:ok, denied_events} =
             ActivityEvent
             |> Ash.Query.for_read(:for_changelog, %{changelog_id: changelog.id}, actor: owner)
             |> Ash.read()

    assert Enum.any?(denied_events, &(&1.outcome == "denied" and is_nil(&1.entry_id)))
    {:ok, entry} = draft(project, changelog, owner, "roles")
    assert {:ok, [source_before]} = sources(entry, member)

    assert {:error, %Ash.Error.Forbidden{}} =
             Changelog.update_draft_markdown(entry, "---\ntitle: denied\n---\n", actor: member)

    assert {:error, :invalid_state_transition} = Changelog.archive_entry(entry, actor: member)
    assert {:error, %Ash.Error.Forbidden{}} = Changelog.publish_entry(entry, 1, actor: member)
    assert {:ok, published} = Changelog.publish_entry(entry, 1, actor: admin)
    assert {:ok, archived} = Changelog.archive_entry(published, actor: admin)
    assert archived.status == :archived
    assert {:error, %Ash.Error.Forbidden{}} = Changelog.restore_to_draft(archived, actor: member)
    assert {:ok, _draft} = Changelog.restore_to_draft(archived, actor: admin)

    assert {:error, %Ash.Error.Forbidden{}} =
             Changelog.update_settings(changelog, %{public_title: "Member updates"},
               actor: member
             )

    assert {:error, :forbidden_role} =
             Changelog.delete_permanently(entry,
               actor: member,
               grant_id: nil,
               correlation_id: Alplus.Id.generate(:request)
             )

    assert {:ok, [_revision | _]} = Changelog.list_revisions(entry, actor: member)
    assert {:ok, [^source_before]} = sources(entry, member)

    assert {:ok, _} =
             Changelog.update_settings(changelog, %{public_title: "Admin updates"}, actor: admin)

    {:ok, admin_entry} = draft(project, changelog, admin, "admin-entry")

    assert :ok =
             Changelog.delete_permanently(admin_entry,
               actor: admin,
               grant_id: nil,
               correlation_id: Alplus.Id.generate(:request)
             )

    assert {:ok, _} =
             Changelog.update_settings(changelog, %{public_title: "Owner updates"}, actor: owner)
  end

  test "vendor flag is outside tenant settings and unique in the database", %{
    org: org,
    owner: owner,
    project: project
  } do
    admin = member_fixture(owner, org, user_fixture(), "admin") |> Scope.put_project(project.id)
    {:ok, changelog} = changelog(project, owner, "vendor-settings")

    assert {:error, _} =
             Changelog.update_settings(changelog, %{vendor?: true}, actor: admin)

    vendor_project = project_fixture(owner, org, %{name: "Vendor project"})
    assert {:ok, vendor} = Changelog.designate_vendor_by_public_token(vendor_project.public_token)
    assert vendor.vendor? == true

    second_project = project_fixture(owner, org, %{name: "Second vendor project"})

    assert {:error, {:vendor_already_assigned, %{id: owner_id}}} =
             Changelog.designate_vendor_by_public_token(second_project.public_token)

    assert owner_id == vendor_project.id
  end

  test "freezes the public slug across archive restore edit and republish", %{
    owner: owner,
    project: project
  } do
    {:ok, changelog} = changelog(project, owner, "freeze")
    {:ok, entry} = draft(project, changelog, owner, "First title")
    {:ok, published} = Changelog.publish_entry(entry, 1, actor: owner)
    slug = published.public_slug

    assert {:ok, archived} = Changelog.archive_entry(published, actor: owner)
    assert {:ok, _draft} = Changelog.restore_to_draft(archived, actor: owner)

    {:ok, edited} =
      Changelog.update_draft_markdown(entry, "---\ntitle: Second title\n---\n\nBody",
        actor: owner
      )

    assert {:ok, republished} = Changelog.publish_entry(edited, 2, actor: owner)
    assert republished.public_slug == slug
  end

  test "requires evidence and accepts every source kind", %{owner: owner, project: project} do
    assert {:ok, _changelog} = changelog(project, owner, "evidence")

    for {kind, index} <-
          Enum.with_index(~w(pull_request issue release deployment commit other), 1) do
      {:ok, entry} =
        Changelog.upsert_draft(
          draft_attrs(project, "evidence-#{index}", "Evidence #{index}")
          |> Map.put(:sources, [%{kind: kind, url: "https://example.com/#{index}"}]),
          actor: owner
        )

      assert {:ok, _} = Changelog.publish_entry(entry, 1, actor: owner)
    end

    assert {:ok, no_evidence} =
             Changelog.upsert_draft(
               draft_attrs(project, "no-evidence", "no-evidence") |> Map.put(:sources, []),
               actor: owner
             )

    assert {:error, :missing_evidence} = Changelog.publish_entry(no_evidence, 1, actor: owner)

    assert {:error, :invalid_source_kind} =
             Changelog.upsert_draft(
               draft_attrs(project, "invalid", "Invalid")
               |> Map.put(:sources, [%{kind: "nope", url: "https://example.com/nope"}]),
               actor: owner
             )
  end

  test "keeps draft revisions mutable and published revisions immutable", %{
    owner: owner,
    project: project
  } do
    {:ok, changelog} = changelog(project, owner, "revisions")
    {:ok, entry} = draft(project, changelog, owner, "Revision")
    assert {:ok, [draft_revision]} = Changelog.list_revisions(entry, actor: owner)

    {:ok, updated} =
      Changelog.update_draft_markdown(entry, "---\ntitle: Updated\n---\n\nBody", actor: owner)

    assert updated.id == entry.id
    assert {:ok, [current]} = Changelog.list_revisions(entry, actor: owner)
    assert current.markdown != draft_revision.markdown
    assert {:error, :stale_revision} = Changelog.publish_entry(entry, 0, actor: owner)
    assert {:ok, _} = Changelog.publish_entry(entry, current.revision_number, actor: owner)
    assert {:ok, [published]} = Changelog.list_revisions(entry, actor: owner)
    assert published.status == :published
    assert {:error, _} = update_revision(published, "---\ntitle: Mutated\n---\nBody", owner)
  end

  test "permanent deletion leaves a content-free slug tombstone", %{
    owner: owner,
    project: project
  } do
    {:ok, changelog} = changelog(project, owner, "delete")
    {:ok, identity} = PublicPages.get_for_project(owner, project.id)
    assert {:ok, _published_identity} = PublicPages.publish(owner, identity)
    {:ok, entry} = draft(project, changelog, owner, "Delete me")
    {:ok, published} = Changelog.publish_entry(entry, 1, actor: owner)
    slug = published.public_slug
    assert {:ok, [revision]} = Changelog.list_revisions(entry, actor: owner)
    grant_id = Alplus.Id.generate(:mcp_oauth_grant)
    assert String.starts_with?(grant_id, "mcogr_")

    assert {:ok, _idempotency_record} =
             Ash.create(
               IdempotencyRecord,
               %{
                 org_id: owner.org_id,
                 tool: "changelog.delete_entry",
                 idempotency_key: "delete-key",
                 request_hash: String.duplicate("a", 64),
                 result: %{
                   "__alplus_mcp_result__" =>
                     Base.encode64(:erlang.term_to_binary(%{entry: %{handle: entry.id}}))
                 }
               },
               authorize?: false
             )

    delete_actor = %{owner | grant_id: grant_id, correlation_id: "req_delete_test"}

    assert :ok = Changelog.delete_permanently(entry, actor: delete_actor)

    assert {:error, :not_found} = Changelog.get_entry(entry.id, actor: owner)
    assert {:error, :not_found} = Changelog.get_revision(revision.id, actor: owner)
    assert {:error, :gone} = Changelog.Public.entry(identity.public_slug, slug)

    assert {:ok, events} = activity_events(changelog, owner)
    assert [%ActivityEvent{} = event] = Enum.filter(events, &(&1.event_type == "entry.deleted"))
    assert event.public_slug == slug
    assert {:ok, []} = Ash.read(IdempotencyRecord, authorize?: false)
    assert event.entry_id == nil
    assert event.grant_id == grant_id
    assert event.correlation_id == "req_delete_test"
    assert event.revision_id == nil
    assert event.request_metadata == %{}
    refute Map.has_key?(event, :markdown)
    refute Map.has_key?(event, :actor_email)
    refute Map.has_key?(event, :credential_id)
  end

  test "permanent deletion rolls back children and idempotency records on failure", %{
    owner: owner,
    project: project
  } do
    {:ok, changelog} = changelog(project, owner, "delete-rollback")
    {:ok, entry} = draft(project, changelog, owner, "Keep me")
    {:ok, published} = Changelog.publish_entry(entry, 1, actor: owner)
    {:ok, [revision]} = Changelog.list_revisions(published, actor: owner)
    {:ok, [source]} = sources(published, owner)

    assert {:ok, _idempotency_record} =
             Ash.create(
               IdempotencyRecord,
               %{
                 org_id: owner.org_id,
                 tool: "changelog.delete_entry",
                 idempotency_key: "rollback-delete-key",
                 request_hash: String.duplicate("b", 64),
                 result: %{
                   "__alplus_mcp_result__" =>
                     Base.encode64(:erlang.term_to_binary(%{entry: %{handle: entry.id}}))
                 }
               },
               authorize?: false
             )

    delete_actor = %{owner | grant_id: Alplus.Id.generate(:mcp_oauth_grant)}

    assert {:error, :injected_failure} =
             Changelog.delete_permanently(published,
               actor: delete_actor,
               after_children: fn -> {:error, :injected_failure} end
             )

    assert {:ok, _entry} = Changelog.get_entry(entry.id, actor: owner)
    assert {:ok, [^revision]} = Changelog.list_revisions(entry, actor: owner)
    assert {:ok, [^source]} = sources(entry, owner)
    assert {:ok, events} = activity_events(changelog, owner)
    refute Enum.any?(events, &(&1.event_type == "entry.deleted"))
    assert {:ok, [_record]} = Ash.read(IdempotencyRecord, authorize?: false)
  end

  test "a member cannot bootstrap a changelog identity", %{
    org: org,
    owner: owner
  } do
    project = project_fixture(owner, org, %{name: "Fresh project", slug: "fresh-project"})

    actor =
      member_fixture(owner, org, user_fixture(), "member")
      |> Scope.put_project(project.id)

    assert {:error, %Ash.Error.Forbidden.Policy{}} =
             Changelog.upsert_draft(
               draft_attrs(project, "fresh-entry", "Fresh entry"),
               actor: actor
             )

    assert {:error, :not_found} = PublicPages.get_for_project(actor, project.id)
  end

  test "validates public slug identity and format", %{
    org: org,
    owner: owner,
    project: project
  } do
    {:ok, changelog} = changelog(project, owner, "taken")
    {:ok, identity} = PublicPages.get_for_project(owner, project.id)
    other_project = project_fixture(owner, org, %{slug: "other-project"})
    other_owner = Scope.put_project(owner, other_project.id)

    assert {:ok, _other_changelog} =
             Changelog.create_changelog(
               %{
                 org_id: org.id,
                 project_id: other_project.id,
                 public_title: "Other",
                 public_slug: identity.public_slug
               },
               actor: other_owner
             )

    assert {:ok, other_identity} = PublicPages.get_for_project(other_owner, other_project.id)
    assert other_identity.public_slug != identity.public_slug

    assert {:error, :legacy_slug_collision} =
             Changelog.update_settings(changelog, %{public_slug: "new-public-slug"}, actor: owner)

    assert {:ok, unchanged_identity} = PublicPages.get_for_project(owner, project.id)
    assert unchanged_identity.public_slug == identity.public_slug

    assert {:error, _} =
             Changelog.update_settings(changelog, %{public_slug: "Not Valid"}, actor: owner)
  end

  test "rolls back a changelog when legacy identity reservation collides", %{
    org: org,
    owner: owner,
    project: project
  } do
    assert {:ok, _status_page} =
             Status.create_page(owner, %{
               org_id: org.id,
               project_id: project.id,
               public_slug: "status-source",
               title: "Status source"
             })

    assert {:ok, identity} = PublicPages.get_for_project(owner, project.id)

    assert :ok =
             PublicPages.reserve_alias(owner, identity, "retry-changelog", "status", nil)

    assert {:ok, _alias} = PublicPages.public_alias_for_slug("retry-changelog")

    attrs = %{
      org_id: org.id,
      project_id: project.id,
      public_title: "Retry changelog",
      public_slug: "retry-changelog"
    }

    assert {:error, _} = Changelog.create_changelog(attrs, actor: owner)
    assert {:error, :not_found} = Changelog.get_changelog(project.id, actor: owner)

    {:ok, alias_record} = PublicPages.public_alias_for_slug("retry-changelog")
    assert {:ok, _deleted} = Repo.delete(alias_record)

    assert {:ok, _changelog} = Changelog.create_changelog(attrs, actor: owner)
  end

  test "rolls back a newly created identity with a failed alias reservation", %{
    org: org,
    owner: owner,
    project: project
  } do
    other_project = project_fixture(owner, org, %{slug: "alias-owner"})
    other_owner = Scope.put_project(owner, other_project.id)

    assert {:ok, other_identity} =
             PublicPages.ensure_identity(other_owner, %{
               org_id: org.id,
               project_id: other_project.id,
               public_slug: "atomic-retry",
               title: "Alias owner"
             })

    assert :ok =
             PublicPages.reserve_alias(
               other_owner,
               other_identity,
               "atomic-retry-old",
               "status",
               nil
             )

    attrs = %{
      org_id: org.id,
      project_id: project.id,
      public_title: "Atomic",
      public_slug: "atomic-retry-old"
    }

    assert {:error, _} = Changelog.create_changelog(attrs, actor: owner)
    assert {:error, :not_found} = PublicPages.get_for_project(owner, project.id)
    assert {:error, :not_found} = Changelog.get_changelog(project.id, actor: owner)

    {:ok, alias_record} = PublicPages.public_alias_for_slug("atomic-retry-old")
    assert {:ok, _} = Repo.delete(alias_record)
    assert {:ok, _} = Changelog.create_changelog(attrs, actor: owner)
  end

  test "enforces one changelog per project and uses shared publication", %{
    owner: owner,
    project: project
  } do
    assert {:ok, changelog} = changelog(project, owner, "unique")
    assert {:error, _} = changelog(project, owner, "duplicate")
    assert {:ok, identity} = PublicPages.get_for_project(owner, project.id)
    assert is_nil(identity.published_at)
    {:ok, entry} = draft(project, changelog, owner, "Activate")
    assert {:ok, _} = Changelog.publish_entry(entry, 1, actor: owner)
    assert {:ok, active} = Changelog.get_changelog(project.id, actor: owner)
    assert {:ok, identity_after_entry} = PublicPages.get_for_project(owner, project.id)
    assert is_nil(identity_after_entry.published_at)
    {:ok, second_entry} = draft(project, active, owner, "Second")
    assert {:ok, _} = Changelog.publish_entry(second_entry, 1, actor: owner)
    assert {:ok, unchanged_identity} = PublicPages.get_for_project(owner, project.id)
    assert unchanged_identity.id == identity.id
    assert {:ok, _published_identity} = PublicPages.publish(owner, unchanged_identity)
  end

  test "the public seam exposes only published shared-page content", %{
    owner: owner,
    project: project
  } do
    {:ok, changelog} = changelog(project, owner, "public")
    {:ok, identity} = PublicPages.get_for_project(owner, project.id)
    assert {:ok, _published_identity} = PublicPages.publish(owner, identity)
    {:ok, _draft_entry} = draft(project, changelog, owner, "draft")
    {:ok, published} = draft(project, changelog, owner, "published")
    {:ok, published} = Changelog.publish_entry(published, 1, actor: owner)
    {:ok, archived} = draft(project, changelog, owner, "archived")
    {:ok, archived} = Changelog.publish_entry(archived, 1, actor: owner)
    {:ok, _} = Changelog.archive_entry(archived, actor: owner)

    assert {:ok, snapshot} = Changelog.Public.load(identity.public_slug)

    assert MapSet.new(Map.keys(snapshot)) ==
             MapSet.new([
               :available_areas,
               :changelog,
               :entries,
               :filters,
               :pagination,
               :public_page
             ])

    assert MapSet.new(Map.keys(snapshot.changelog)) ==
             MapSet.new([:public_slug, :public_title, :logo_url])

    assert {:ok, by_project} = Changelog.Public.load_for_project(project.id)
    assert by_project == snapshot

    assert {:ok, _} =
             Changelog.update_settings(changelog, %{public_slug: "public-renamed"}, actor: owner)

    assert {:ok, %{identity: %{public_slug: "public-renamed"}}} =
             PublicPages.resolve("public-renamed", alias_kind: "changelog")

    assert {:ok, %{identity: %{public_slug: "public-renamed"}, alias?: true}} =
             PublicPages.resolve(identity.public_slug, alias_kind: "changelog")

    assert Enum.all?(
             snapshot.entries,
             &(MapSet.new(Map.keys(&1)) ==
                 MapSet.new([
                   :area,
                   :html,
                   :media_alt,
                   :media_caption,
                   :media_url,
                   :published_at,
                   :public_slug,
                   :summary,
                   :title,
                   :version
                 ]))
           )

    assert {:ok, _} = Changelog.Public.entry(identity.public_slug, published.public_slug)

    assert {:error, :not_found} =
             Changelog.Public.entry(identity.public_slug, archived.public_slug)
  end

  test "bootstraps globally unique public slugs for projects in different organizations" do
    {org_one, owner_one} = org_fixture(scope_fixture())
    {org_two, owner_two} = org_fixture(scope_fixture())
    project_one = project_fixture(owner_one, org_one, %{slug: "app"})
    project_two = project_fixture(owner_two, org_two, %{slug: "app"})
    actor_one = Scope.put_project(owner_one, project_one.id)
    actor_two = Scope.put_project(owner_two, project_two.id)

    {:ok, entry_one} = draft(project_one, nil, actor_one, "same-slug")
    {:ok, entry_two} = draft(project_two, nil, actor_two, "same-slug")
    {:ok, changelog_one} = Changelog.get_changelog(project_one.id, actor: actor_one)
    {:ok, _changelog_two} = Changelog.get_changelog(project_two.id, actor: actor_two)
    {:ok, identity_one} = PublicPages.get_for_project(actor_one, project_one.id)
    {:ok, identity_two} = PublicPages.get_for_project(actor_two, project_two.id)
    assert {:ok, _published_one} = PublicPages.publish(actor_one, identity_one)
    assert {:ok, _published_two} = PublicPages.publish(actor_two, identity_two)

    assert identity_one.public_slug == "app"
    assert identity_two.public_slug != "app"
    assert identity_two.public_slug =~ "app-"

    assert {:ok, _} = Changelog.publish_entry(entry_one, 1, actor: actor_one)
    assert {:ok, _} = Changelog.publish_entry(entry_two, 1, actor: actor_two)
    assert {:ok, _} = Changelog.Public.load(identity_one.public_slug)
    assert {:ok, _} = Changelog.Public.load(identity_two.public_slug)

    assert {:error, :not_found} =
             Changelog.update_settings(
               changelog_one,
               %{public_title: "Other tenant"},
               actor: actor_two
             )
  end

  test "revises by entry handle across grants without changing implicit identity", %{
    owner: owner,
    project: project
  } do
    {:ok, _changelog} = changelog(project, owner, "rotation")
    first_grant = Alplus.Id.generate(:mcp_oauth_grant)
    second_grant = Alplus.Id.generate(:mcp_oauth_grant)
    assert String.starts_with?(first_grant, "mcogr_")
    assert String.starts_with?(second_grant, "mcogr_")
    first_actor = %{owner | grant_id: first_grant}
    second_actor = %{owner | grant_id: second_grant}

    attrs = draft_attrs(project, "release-1", "Release 1")

    {:ok, entry} =
      Changelog.upsert_draft(%{attrs | grant_id: first_grant}, actor: first_actor)

    assert entry.grant_id == first_grant
    assert {:ok, _} = Changelog.publish_entry(entry, 1, actor: first_actor)

    revised =
      attrs
      |> Map.put(:grant_id, second_grant)
      |> Map.put(:entry_handle, entry.id)
      |> Map.put(:markdown, "---\ntitle: Release 2\n---\n\nBody Release 2")

    assert {:ok, same_entry} = Changelog.upsert_draft(revised, actor: second_actor)
    assert same_entry.id == entry.id
    assert same_entry.grant_id == first_grant
    assert {:ok, revisions} = Changelog.list_revisions(entry, actor: second_actor)
    assert length(revisions) == 2

    assert {:ok, own_entry} =
             Changelog.upsert_draft(
               %{attrs | grant_id: second_grant},
               actor: second_actor
             )

    assert own_entry.id != entry.id
    assert own_entry.external_id == entry.external_id
    assert own_entry.grant_id == second_grant
  end

  test "returns stable errors for repeated and invalid lifecycle transitions", %{
    owner: owner,
    project: project
  } do
    {:ok, changelog} = changelog(project, owner, "states")
    {:ok, entry} = draft(project, changelog, owner, "states")
    assert {:ok, published} = Changelog.publish_entry(entry, 1, actor: owner)
    assert {:error, :already_published} = Changelog.publish_entry(published, 1, actor: owner)
    assert {:ok, archived} = Changelog.archive_entry(published, actor: owner)

    assert {:error, :invalid_state_transition} =
             Changelog.publish_entry(archived, 1, actor: owner)

    assert {:ok, restored} = Changelog.restore_to_draft(archived, actor: owner)

    assert {:error, :invalid_state_transition} =
             Changelog.restore_to_draft(restored, actor: owner)
  end

  defp changelog(project, actor, suffix) do
    Changelog.create_changelog(
      %{
        org_id: project.org_id,
        project_id: project.id,
        public_title: "Changelog #{suffix}",
        public_slug: "#{suffix}-#{System.unique_integer([:positive])}"
      },
      actor: actor
    )
  end

  defp draft(project, _changelog, actor, external_id) do
    Changelog.upsert_draft(draft_attrs(project, external_id, external_id), actor: actor)
  end

  defp draft_attrs(project, external_id, title) do
    %{
      project_id: project.id,
      grant_id: Alplus.Id.generate(:mcp_oauth_grant),
      external_id: external_id,
      markdown: "---\ntitle: #{title}\n---\n\nBody #{title}",
      sources: [%{kind: "commit", url: "https://example.com/#{external_id}"}]
    }
  end

  defp sources(entry, actor) do
    SourceReference
    |> Ash.Query.for_read(:for_entry, %{entry_id: entry.id}, actor: actor)
    |> Ash.read()
  end

  defp get_source(id, actor) do
    SourceReference
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read()
    |> case do
      {:ok, [source]} -> {:ok, source}
      {:ok, []} -> {:error, :not_found}
      other -> other
    end
  end

  defp update_revision(revision, markdown, actor) do
    Ash.Changeset.for_update(revision, :update, %{markdown: markdown}, actor: actor)
    |> Ash.update()
  end

  defp activity_events(changelog, actor) do
    ActivityEvent
    |> Ash.Query.for_read(:for_changelog, %{changelog_id: changelog.id}, actor: actor)
    |> Ash.read()
  end
end
