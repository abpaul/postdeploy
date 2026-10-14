defmodule Alplus.Changelog.EntryCountsTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures
  alias Alplus.{Changelog, Scope}
  require Ash.Query

  defp entry(actor, project, changelog, status) do
    Ash.create!(
      Changelog.Entry,
      %{
        org_id: actor.org_id,
        project_id: project.id,
        changelog_id: changelog.id,
        grant_id: Alplus.Id.generate(:mcp_oauth_grant),
        external_id: "counts-#{System.unique_integer([:positive])}",
        title: "An update",
        summary: "An update for customers.",
        status: status
      },
      actor: actor
    )
  end

  defp project_with_changelog(owner, org) do
    project = project_fixture(owner, org)
    actor = Scope.put_project(owner, project.id)

    {:ok, changelog} =
      Changelog.create_changelog(
        %{
          org_id: org.id,
          project_id: project.id,
          public_title: "Counts",
          public_slug: "counts-#{System.unique_integer([:positive])}"
        },
        actor: actor
      )

    {project, actor, changelog}
  end

  test "counts each status and reflects lifecycle changes without caching" do
    {org, owner} = org_fixture(scope_fixture())
    {project, actor, changelog} = project_with_changelog(owner, org)

    assert {:ok, %{draft: 0, published: 0, archived: 0}} =
             Changelog.entry_counts(project.id, actor: actor)

    entry(actor, project, changelog, :draft)
    entry(actor, project, changelog, :draft)
    published = entry(actor, project, changelog, :published)
    entry(actor, project, changelog, :archived)

    assert {:ok, %{draft: 2, published: 1, archived: 1}} =
             Changelog.entry_counts(project.id, actor: actor)

    Ash.update!(published, %{}, action: :archive, actor: actor)

    assert {:ok, %{draft: 2, published: 0, archived: 2}} =
             Changelog.entry_counts(project.id, actor: actor)
  end

  test "counts honor project, organization, and current membership" do
    {org, owner} = org_fixture(scope_fixture())
    {project, actor, changelog} = project_with_changelog(owner, org)
    entry(actor, project, changelog, :draft)
    {other_project, other_actor, other_changelog} = project_with_changelog(owner, org)
    entry(other_actor, other_project, other_changelog, :published)
    {foreign_org, foreign_owner} = org_fixture(scope_fixture())

    {foreign_project, foreign_actor, foreign_changelog} =
      project_with_changelog(foreign_owner, foreign_org)

    entry(foreign_actor, foreign_project, foreign_changelog, :archived)
    member = user_fixture()
    member_actor = member_fixture(owner, org, member, "member") |> Scope.put_project(project.id)

    assert {:ok, %{draft: 1, published: 0, archived: 0}} =
             Changelog.entry_counts(project.id, actor: member_actor)

    assert {:ok, %{draft: 0, published: 0, archived: 0}} =
             Changelog.entry_counts(other_project.id, actor: member_actor)

    assert {:ok, %{draft: 0, published: 0, archived: 0}} =
             Changelog.entry_counts(foreign_project.id,
               actor: Scope.put_project(member_actor, foreign_project.id)
             )

    membership =
      Alplus.Orgs.Membership
      |> Ash.Query.filter(org_id == ^org.id and user_id == ^member.id)
      |> Ash.read_one!(actor: owner)

    Ash.destroy!(membership, actor: owner)

    assert {:ok, %{draft: 0, published: 0, archived: 0}} =
             Changelog.entry_counts(project.id, actor: member_actor)
  end
end
