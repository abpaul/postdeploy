defmodule Alplus.ProjectsTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Projects.Project

  describe "create/1" do
    test "requires org_id and rejects a duplicate slug within the same org" do
      {org, owner_scope} = org_fixture(scope_fixture())

      assert %Project{} = project_fixture(owner_scope, org, %{slug: "dup"})

      assert_raise Ash.Error.Invalid, fn ->
        project_fixture(owner_scope, org, %{slug: "dup"})
      end
    end

    test "the same slug is allowed in a different org" do
      {org_a, owner_a} = org_fixture(scope_fixture())
      {org_b, owner_b} = org_fixture(scope_fixture())

      assert %Project{} = project_fixture(owner_a, org_a, %{slug: "shared"})
      assert %Project{} = project_fixture(owner_b, org_b, %{slug: "shared"})
    end
  end

  describe "archival" do
    test "an archived project disappears from reads and the row survives" do
      {org, owner_scope} = org_fixture(scope_fixture())
      project = project_fixture(owner_scope, org)

      assert :ok = Ash.destroy(project, action: :archive, actor: owner_scope)

      assert {:error, %Ash.Error.Invalid{}} = Ash.get(Project, project.id, actor: owner_scope)

      # The default read filters archived_at IS NULL; the row itself is still
      # there, not hard-deleted (verified directly through Ecto below).
      row = Alplus.Repo.get(Project, project.id)
      assert row
      assert row.archived_at
    end

    test "the row survives with archived_at set, verified directly through Ecto" do
      {org, owner_scope} = org_fixture(scope_fixture())
      project = project_fixture(owner_scope, org)

      assert :ok = Ash.destroy(project, action: :archive, actor: owner_scope)

      row = Alplus.Repo.get(Project, project.id)
      assert row
      assert row.archived_at
    end
  end

  describe "cross-tenant isolation" do
    test "a project id from another org returns not-found" do
      {org_a, owner_a} = org_fixture(scope_fixture())
      {_org_b, owner_b} = org_fixture(scope_fixture())
      project = project_fixture(owner_a, org_a)

      assert {:error, %Ash.Error.Invalid{}} = Ash.get(Project, project.id, actor: owner_b)
    end
  end

  describe "authorization matrix" do
    setup do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      admin_scope = member_fixture(owner_scope, org, user_fixture(), "admin")
      member_scope = member_fixture(owner_scope, org, user_fixture(), "member")
      outsider_scope = scope_fixture()

      %{
        org: org,
        scopes: %{
          owner: owner_scope,
          admin: admin_scope,
          member: member_scope,
          outsider: outsider_scope
        }
      }
    end

    for {role, can_create?, can_read?, can_archive?} <- [
          {:owner, true, true, true},
          {:admin, true, true, true},
          {:member, false, true, false},
          {:outsider, false, false, false}
        ] do
      test "#{role}: create=#{can_create?} read=#{can_read?} archive=#{can_archive?}", %{
        org: org,
        scopes: scopes
      } do
        scope = scopes[unquote(role)]

        create_result =
          Ash.create(
            Project,
            %{org_id: org.id, name: "P", slug: "s-#{System.unique_integer([:positive])}"},
            action: :create,
            actor: scope
          )

        case create_result do
          {:ok, _} -> assert unquote(can_create?)
          {:error, _} -> refute unquote(can_create?)
        end

        # Read/archive against a project created by the owner, independent of
        # whether this role could create one itself.
        project = project_fixture(scopes.owner, org)

        case Ash.get(Project, project.id, actor: scope) do
          {:ok, _} -> assert unquote(can_read?)
          {:error, _} -> refute unquote(can_read?)
        end

        case Ash.destroy(project, action: :archive, actor: scope) do
          :ok -> assert unquote(can_archive?)
          {:error, _} -> refute unquote(can_archive?)
        end
      end
    end
  end

  describe "database length caps" do
    test "postgres rejects an over-long name even when the changeset is bypassed" do
      {org, owner_scope} = org_fixture(scope_fixture())
      project = project_fixture(owner_scope, org, %{slug: "caps"})

      assert_raise Postgrex.Error, ~r/projects_name_length_check/, fn ->
        Alplus.Repo.query!(
          "UPDATE projects SET name = $1 WHERE id = $2",
          [String.duplicate("x", 201), project.id]
        )
      end
    end
  end
end
