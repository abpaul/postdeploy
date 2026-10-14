defmodule Alplus.PublicPagesTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Changelog
  alias Alplus.PublicPages
  alias Alplus.PublicPages.PublicPageAlias
  alias Alplus.PublicPages.Public
  alias Alplus.Scope
  alias Alplus.Status

  setup do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)

    %{org: org, project: project, scope: scope}
  end

  test "reuses one identity when both public surfaces are configured", context do
    assert {:ok, _status_page} =
             Status.create_page(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               public_slug: "shared-public",
               title: "Shared status"
             })

    assert {:ok, changelog} =
             Changelog.create_changelog(
               %{
                 org_id: context.org.id,
                 project_id: context.project.id,
                 public_slug: "shared-updates",
                 public_title: "Shared updates",
                 enabled: true
               },
               actor: context.scope
             )

    assert {:ok, identity} = PublicPages.get_for_project(context.scope, context.project.id)
    assert identity.project_id == context.project.id
    assert identity.public_slug == "shared-public"
    assert identity.title == "Shared status"
    assert identity.id != changelog.id

    assert {:ok, same_identity} =
             PublicPages.ensure_identity(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               public_slug: "another-slug",
               title: "Another title"
             })

    assert same_identity.id == identity.id
  end

  test "displaces a cross-surface slug with the project's public token", context do
    assert {:ok, _changelog} =
             Changelog.create_changelog(
               %{
                 org_id: context.org.id,
                 project_id: context.project.id,
                 public_slug: "shared-public",
                 public_title: "Shared updates",
                 enabled: true
               },
               actor: context.scope
             )

    {other_org, other_owner_scope} = org_fixture(scope_fixture())
    other_project = project_fixture(other_owner_scope, other_org)
    other_scope = Scope.put_project(other_owner_scope, other_project.id)

    assert {:ok, _status_page} =
             Status.create_page(other_scope, %{
               org_id: other_org.id,
               project_id: other_project.id,
               public_slug: "shared-public",
               title: "Shared status"
             })

    assert {:ok, first_identity} = PublicPages.get_for_project(context.scope, context.project.id)
    assert {:ok, second_identity} = PublicPages.get_for_project(other_scope, other_project.id)
    assert first_identity.public_slug == "shared-public"

    assert second_identity.public_slug ==
             "shared-public-" <> String.downcase(other_project.public_token)
  end

  test "public reads use one not-found result for unpublished, unknown, and inactive identities",
       context do
    assert {:ok, identity} =
             PublicPages.ensure_identity(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               public_slug: "public-page",
               title: "Public page"
             })

    assert {:error, :not_found} = Public.resolve(identity.public_slug)
    assert {:error, :not_found} = Public.resolve("does-not-exist")

    assert {:ok, _published} = PublicPages.publish(context.scope, identity)
    assert {:ok, %{identity: published}} = Public.resolve(identity.public_slug)
    assert published.id == identity.id

    assert :ok = Alplus.Orgs.apply_billing_status(context.org.id, "canceled")

    assert {:error, :not_found} = Public.resolve(identity.public_slug)
  end

  test "legacy aliases resolve to the published project identity", context do
    assert {:ok, identity} =
             PublicPages.ensure_identity(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               public_slug: "canonical-status",
               title: "Canonical status"
             })

    assert {:ok, _identity} = PublicPages.publish(context.scope, identity)

    assert {:ok, _alias} =
             Ash.create(
               PublicPageAlias,
               %{
                 id: "palias_test_#{System.unique_integer([:positive])}",
                 org_id: context.org.id,
                 project_id: context.project.id,
                 public_page_id: identity.id,
                 public_slug: "legacy-status",
                 kind: "status"
               },
               action: :create,
               actor: context.scope
             )

    assert {:ok, %{identity: resolved, alias?: true, requested_slug: "legacy-status"}} =
             Public.resolve("legacy-status")

    assert resolved.id == identity.id
  end

  test "a status-owned identity keeps the Changelog slug as a typed alias", context do
    assert {:ok, _status_page} =
             Status.create_page(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               status_slug: "status-canonical",
               title: "Status canonical"
             })

    assert {:ok, _changelog} =
             Changelog.create_changelog(
               %{
                 org_id: context.org.id,
                 project_id: context.project.id,
                 public_slug: "changelog-legacy",
                 public_title: "Changelog legacy",
                 enabled: true
               },
               actor: context.scope
             )

    assert {:ok, identity} = PublicPages.get_for_project(context.scope, context.project.id)
    assert identity.public_slug == "status-canonical"
    assert {:ok, _published} = PublicPages.publish(context.scope, identity)

    assert {:ok, alias_record} =
             PublicPages.public_alias_for_slug("changelog-legacy", kind: "changelog")

    assert alias_record.kind == "changelog"
    assert alias_record.public_page_id == identity.id

    assert {:ok, %{identity: resolved, alias?: true}} =
             Public.resolve_changelog("changelog-legacy")

    assert resolved.id == identity.id
    assert {:error, :not_found} = Public.resolve("changelog-legacy", alias_kind: "status")

    assert :ok =
             PublicPages.reserve_alias(
               context.scope,
               identity,
               "legacy-status",
               "status",
               "status-source"
             )

    assert {:error, :not_found} = Changelog.Public.load_for_legacy_slug("legacy-status")
  end

  test "a project cannot read another project's public identity", context do
    {other_org, other_owner_scope} = org_fixture(scope_fixture())
    other_project = project_fixture(other_owner_scope, other_org)
    other_scope = Scope.put_project(other_owner_scope, other_project.id)

    assert {:ok, _other_identity} =
             PublicPages.ensure_identity(other_scope, %{
               org_id: other_org.id,
               project_id: other_project.id,
               public_slug: "other-tenant-status",
               title: "Other tenant status"
             })

    assert {:error, :not_found} =
             PublicPages.get_for_project(context.scope, other_project.id)

    assert {:ok, _identity} =
             PublicPages.ensure_identity(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               public_slug: "tenant-status",
               title: "Tenant status"
             })
  end

  test "changing a slug cannot shadow another project's legacy alias", context do
    assert {:ok, identity} =
             PublicPages.ensure_identity(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               public_slug: "first-canonical",
               title: "First"
             })

    {other_org, other_owner_scope} = org_fixture(scope_fixture())
    other_project = project_fixture(other_owner_scope, other_org)
    other_scope = Scope.put_project(other_owner_scope, other_project.id)

    assert {:ok, other_identity} =
             PublicPages.ensure_identity(other_scope, %{
               org_id: other_org.id,
               project_id: other_project.id,
               public_slug: "other-canonical",
               title: "Other"
             })

    assert :ok =
             PublicPages.reserve_alias(
               other_scope,
               other_identity,
               "legacy-owned",
               "status",
               nil
             )

    assert {:error, :legacy_slug_collision} =
             PublicPages.update(context.scope, identity, %{public_slug: "legacy-owned"})
  end

  test "changing a slug preserves the old canonical URL and is idempotent", context do
    assert {:ok, identity} =
             PublicPages.ensure_identity(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               public_slug: "original-page",
               title: "Original"
             })

    assert {:ok, updated} =
             PublicPages.update(context.scope, identity, %{public_slug: "renamed-page"})

    assert {:ok, alias_record} = PublicPages.public_alias_for_slug("original-page")
    assert alias_record.public_page_id == identity.id

    assert :ok =
             PublicPages.reserve_alias(context.scope, updated, "original-page", "status", nil)
  end

  test "lists retained aliases only for the scoped project", context do
    assert {:ok, identity} =
             PublicPages.ensure_identity(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               public_slug: "current-page",
               title: "Current"
             })

    assert {:ok, updated} =
             PublicPages.update(context.scope, identity, %{public_slug: "renamed-page"})

    assert {:ok, aliases} = PublicPages.aliases_for_project(context.scope, context.project.id)
    assert Enum.map(aliases, & &1.public_slug) == ["current-page"]
    assert hd(aliases).public_page_id == updated.id

    {other_org, other_owner_scope} = org_fixture(scope_fixture())
    other_project = project_fixture(other_owner_scope, other_org)
    other_scope = Scope.put_project(other_owner_scope, other_project.id)

    assert {:error, :not_found} =
             PublicPages.aliases_for_project(context.scope, other_project.id)

    assert {:ok, _} = PublicPages.aliases_for_project(other_scope, other_project.id)
  end

  test "rejects logo URLs that are not HTTP or HTTPS", context do
    assert {:error, error} =
             PublicPages.ensure_identity(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               public_slug: "invalid-logo",
               title: "Invalid logo",
               logo_url: "javascript:alert(1)"
             })

    assert Exception.message(error) =~ "logo_url"
    assert Exception.message(error) =~ "HTTP or HTTPS"
  end

  test "preflight selects a published Status workspace before a changelog", context do
    assert {:ok, _page} =
             Status.create_page(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               public_slug: "status-source",
               title: "Status source"
             })

    assert {:ok, identity} = PublicPages.get_for_project(context.scope, context.project.id)
    assert {:ok, _published} = PublicPages.publish(context.scope, identity)

    assert {:ok, _changelog} =
             Changelog.create_changelog(
               %{
                 org_id: context.org.id,
                 project_id: context.project.id,
                 public_slug: "changelog-source",
                 public_title: "Changelog source",
                 enabled: true
               },
               actor: context.scope
             )

    assert [decision] = Alplus.PublicPages.Migration.preflight()
    assert decision.project_id == context.project.id
    assert decision.surface == :status
    assert decision.source_slug == "status-source"
    assert decision.public_slug == "status-source"
    assert decision.decision == :reuse
    assert decision.multiple_status_pages == false
    assert decision.alias_conflicts == []
  end

  test "preflight keeps a draft Status source ahead of a published Changelog", context do
    assert {:ok, _page} =
             Status.create_page(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               public_slug: "draft-status",
               title: "Draft status"
             })

    assert {:ok, _changelog} =
             Changelog.create_changelog(
               %{
                 org_id: context.org.id,
                 project_id: context.project.id,
                 public_slug: "published-changelog",
                 public_title: "Published changelog",
                 enabled: true
               },
               actor: context.scope
             )

    assert [decision] = Alplus.PublicPages.Migration.preflight()
    assert decision.surface == :status
    assert decision.source_slug == "draft-status"
    assert decision.published_at == nil
  end

  test "relationship verification reports no retired workspace rows for one page", context do
    assert {:ok, _page} =
             Status.create_page(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               public_slug: "verified-status",
               title: "Verified status"
             })

    assert [] = Alplus.PublicPages.Verification.relationship_counts()
  end
end
