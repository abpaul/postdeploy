defmodule Alplus.Changelog.VendorDesignationTaskTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Changelog
  alias Alplus.Changelog.Changelog, as: ChangelogResource
  alias Alplus.Orgs.Organization
  alias Alplus.PublicPages
  alias Alplus.Projects.Project
  alias Alplus.Scope

  require Ash.Query

  setup do
    scope = scope_fixture()
    {org, owner} = org_fixture(scope)

    project =
      project_fixture(owner, org, %{
        name: "Vendor project #{System.unique_integer([:positive])}",
        slug: "vendor-project-#{System.unique_integer([:positive])}"
      })

    {:ok, org: org, owner: owner, project: project}
  end

  test "designates an existing changelog and serves it from /changelog", context do
    scope = Scope.put_project(context.owner, context.project.id)

    {:ok, _changelog} =
      Changelog.create_changelog(
        %{
          org_id: context.org.id,
          project_id: context.project.id,
          public_title: "Existing updates",
          public_slug: "existing-updates",
          enabled: true
        },
        actor: scope
      )

    {:ok, identity} = PublicPages.get_for_project(scope, context.project.id)
    assert {:ok, _published_identity} = PublicPages.publish(scope, identity)

    {:ok, entry} =
      Changelog.upsert_draft(
        %{
          project_id: context.project.id,
          grant_id: Alplus.Id.generate(:mcp_oauth_grant),
          external_id: "existing-#{System.unique_integer([:positive])}",
          markdown: "---\ntitle: Existing update\n---\nBody",
          sources: [%{kind: "release", url: "https://example.test/release"}]
        },
        actor: scope
      )

    assert {:ok, _published} = Changelog.publish_entry(entry, 1, actor: scope)
    run_task(context.project.public_token)

    conn = get(build_conn(), "/changelog")
    assert conn.status == 200
    assert response(conn, 200) =~ "Existing update"
  end

  test "creates only the missing changelog", context do
    organizations_before =
      Ash.read!(Ash.Query.for_read(Organization, :read, %{}), authorize?: false)

    projects_before = Ash.read!(Ash.Query.for_read(Project, :read, %{}), authorize?: false)

    run_task(context.project.public_token)

    assert Ash.read!(Ash.Query.for_read(Organization, :read, %{}), authorize?: false) ==
             organizations_before

    assert Ash.read!(Ash.Query.for_read(Project, :read, %{}), authorize?: false) ==
             projects_before

    owner = Scope.put_project(context.owner, context.project.id)
    assert {:ok, changelog} = Changelog.get_changelog(context.project.id, actor: owner)
    assert changelog.project_id == context.project.id
    assert {:ok, identity} = PublicPages.get_for_project(owner, context.project.id)
    assert identity.title == context.project.name
    assert identity.public_slug == context.project.slug
  end

  test "running the task twice leaves one vendor changelog", context do
    run_task(context.project.public_token)
    run_task(context.project.public_token)

    assert vendor_count() == 1
  end

  test "refuses a project when another changelog owns the vendor flag", context do
    other_project =
      project_fixture(context.owner, context.org, %{
        name: "Other vendor project #{System.unique_integer([:positive])}",
        slug: "other-vendor-project-#{System.unique_integer([:positive])}"
      })

    run_task(other_project.public_token)

    error =
      assert_raise Mix.Error, fn ->
        run_task(context.project.public_token)
      end

    assert Exception.message(error) =~ other_project.name
    assert Exception.message(error) =~ other_project.public_token
    assert vendor_count() == 1
  end

  test "fails loudly for an unknown public token", _context do
    error =
      assert_raise Mix.Error, fn ->
        run_task(Alplus.PublicToken.generate())
      end

    assert Exception.message(error) =~ "No project found with public token"
  end

  test "renders the empty state before a vendor changelog exists", _context do
    conn = get(build_conn(), "/changelog")

    assert conn.status == 200
    assert response(conn, 200) =~ "No updates are published yet."
  end

  defp run_task(public_token) do
    Mix.Task.reenable("alplus.changelog.designate_vendor")
    Mix.Task.run("alplus.changelog.designate_vendor", [public_token])
  end

  defp vendor_count do
    ChangelogResource
    |> Ash.Query.for_read(:read, %{}, authorize?: false)
    |> Ash.Query.filter(vendor? == true)
    |> Ash.read!(authorize?: false)
    |> length()
  end
end
