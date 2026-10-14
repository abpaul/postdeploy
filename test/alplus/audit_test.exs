defmodule Alplus.AuditTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures
  import Alplus.AuditFixtures

  require Ash.Query

  alias Alplus.Audit.AuditLog
  alias Alplus.Orgs.Membership
  alias Alplus.Projects.Project

  defp rows_for(org_id) do
    AuditLog
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp audit_row(scope, project, attrs) do
    Alplus.Audit.write(
      Map.merge(
        %{
          actor: Alplus.Scope.put_project(scope, project.id),
          org_id: scope.org_id,
          project_id: project.id,
          actor_kind: "agent",
          transport: "remote_mcp",
          action: "monitor.list",
          subject_type: "mcp_tool",
          outcome: "allowed"
        },
        attrs
      )
    )
  end

  describe "allowed sensitive mutations" do
    test "organization.create writes exactly one allowed row with the creating actor" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)

      rows = rows_for(org.id)
      assert [row] = Enum.filter(rows, &(&1.action == "organization.create"))
      assert row.outcome == "allowed"
      assert row.actor_id == owner_scope.user_id
      assert row.org_id == org.id
      assert row.subject_type == "organization"
      assert row.subject_id == org.id
    end

    test "organization.update writes exactly one allowed row" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)

      Ash.update!(org, %{name: "Renamed"}, action: :update, actor: owner_scope)

      rows = rows_for(org.id) |> Enum.filter(&(&1.action == "organization.update"))
      assert [row] = rows
      assert row.outcome == "allowed"
      assert row.actor_id == owner_scope.user_id
    end

    test "organization.ownership_transfer writes exactly one allowed row" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      new_owner_user = user_fixture()
      admin_scope = member_fixture(owner_scope, org, new_owner_user, "admin")

      target =
        Membership
        |> Ash.Query.filter(org_id == ^org.id and user_id == ^new_owner_user.id)
        |> Ash.read_one!(actor: owner_scope)

      Ash.update!(target, %{}, action: :promote_to_owner, actor: owner_scope)

      rows =
        rows_for(org.id) |> Enum.filter(&(&1.action == "organization.ownership_transfer"))

      assert [row] = rows
      assert row.outcome == "allowed"
      assert row.actor_id == owner_scope.user_id
      _ = admin_scope
    end

    test "membership.add, membership.role_change, membership.remove each write one allowed row" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      target_user = user_fixture()
      subscribed_fixture(org)

      Ash.create!(Membership, %{org_id: org.id, user_id: target_user.id, role: "member"},
        action: :add_member,
        actor: owner_scope
      )

      target =
        Membership
        |> Ash.Query.filter(org_id == ^org.id and user_id == ^target_user.id)
        |> Ash.read_one!(actor: owner_scope)

      Ash.update!(target, %{role: "admin"}, action: :change_role, actor: owner_scope)
      Ash.destroy!(target, actor: owner_scope)

      rows = rows_for(org.id)
      assert [_] = Enum.filter(rows, &(&1.action == "membership.add"))
      assert [_] = Enum.filter(rows, &(&1.action == "membership.role_change"))
      assert [_] = Enum.filter(rows, &(&1.action == "membership.remove"))
    end

    test "organization.destroy erases the org's entire audit trail, never crashing the write" do
      # Founder decision: destroying an org is GDPR-style right to erasure,
      # not a preserved trail — `audit_logs.org_id` is `ON DELETE CASCADE`
      # against `organizations`, so every row for the org (its own
      # `organization.destroy` included) disappears with it.
      # `Alplus.Audit.Change` skips writing the destroy event's own row on
      # purpose (it would be erased by this same cascade the instant it
      # landed) rather than attempt a doomed insert — this used to log
      # "Alplus.Audit.write/1 failed: ... org_id: does not exist" every
      # time an org was destroyed (test/alplus/orgs_test.exs reproduced
      # it); the regression to guard is that crash, not a missing row.
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      org_id = org.id

      # Prior audit history exists for this org (at least "organization
      # .create") before it is erased.
      assert rows_for(org_id) != []

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Ash.destroy(org, actor: owner_scope)
        end)

      refute log =~ "Alplus.Audit.write/1 failed"

      assert AuditLog
             |> Ash.Query.filter(subject_type == "organization" and subject_id == ^org_id)
             |> Ash.read!(authorize?: false) == []

      assert rows_for(org_id) == []
    end

    test "a denied organization.destroy still records normally (only a successful destroy erases)" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      member_scope = member_fixture(owner_scope, org, user_fixture(), "member")

      assert {:error, _} = Ash.destroy(org, actor: member_scope)

      rows = rows_for(org.id) |> Enum.filter(&(&1.action == "organization.destroy"))
      assert [row] = rows
      assert row.outcome == "denied"
      assert row.actor_id == member_scope.user_id
    end

    test "project.create and project.archive each write one allowed row with project_id" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      project = project_fixture(owner_scope, org)

      Ash.destroy!(project, action: :archive, actor: owner_scope)

      rows = rows_for(org.id)
      assert [create_row] = Enum.filter(rows, &(&1.action == "project.create"))
      assert create_row.project_id == project.id
      assert create_row.subject_type == "project"

      assert [archive_row] = Enum.filter(rows, &(&1.action == "project.archive"))
      assert archive_row.project_id == project.id
    end
  end

  describe "denied sensitive actions" do
    test "a member denied project.create writes exactly one denied row" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      member_scope = member_fixture(owner_scope, org, user_fixture(), "member")

      assert {:error, _} =
               Ash.create(Project, %{org_id: org.id, name: "Nope", slug: "nope"},
                 action: :create,
                 actor: member_scope
               )

      rows = rows_for(org.id) |> Enum.filter(&(&1.action == "project.create"))
      assert [row] = rows
      assert row.outcome == "denied"
      assert row.actor_id == member_scope.user_id
    end

    test "a member denied organization.update writes exactly one denied row" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      member_scope = member_fixture(owner_scope, org, user_fixture(), "member")

      assert {:error, _} = Ash.update(org, %{name: "Nope"}, action: :update, actor: member_scope)

      rows = rows_for(org.id) |> Enum.filter(&(&1.action == "organization.update"))
      assert [row] = rows
      assert row.outcome == "denied"
      assert row.actor_id == member_scope.user_id
    end

    test "a plain validation failure is not audited as denied" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)

      # slug fails the format constraint — a validation error, not a policy
      # denial, so no audit row should exist for this attempt.
      assert {:error, _} =
               Ash.create(Project, %{org_id: org.id, name: "Bad Slug", slug: "Not Valid!"},
                 action: :create,
                 actor: owner_scope
               )

      rows = rows_for(org.id) |> Enum.filter(&(&1.action == "project.create"))
      refute Enum.any?(rows, &(&1.outcome == "denied"))
    end
  end

  describe "AuditLog itself" do
    test "no actor can write a row directly, even the owner" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.create(
                 AuditLog,
                 %{
                   org_id: org.id,
                   actor_id: owner_scope.user_id,
                   action: "forged",
                   subject_type: "organization",
                   subject_id: org.id,
                   outcome: "allowed"
                 },
                 action: :record,
                 actor: owner_scope
               )
    end

    test "owner/admin can read their org's audit log; a plain member cannot" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      member_scope = member_fixture(owner_scope, org, user_fixture(), "member")

      assert {:ok, _rows} =
               AuditLog
               |> Ash.Query.filter(org_id == ^org.id)
               |> Ash.read(actor: owner_scope)

      assert {:ok, []} =
               AuditLog
               |> Ash.Query.filter(org_id == ^org.id)
               |> Ash.read(actor: member_scope)
    end

    test "never stores a raw ip address for these mutations" do
      owner = scope_fixture()
      {org, _owner_scope} = org_fixture(owner)

      rows = rows_for(org.id)
      assert rows != []
      assert Enum.all?(rows, &is_nil(&1.ip_address))
    end
  end

  describe "agent connection predicates" do
    test "agent_connected?/2 is false until an allowed agent reaches the project over MCP" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      project = project_fixture(owner_scope, org)

      refute Alplus.Audit.agent_connected?(org.id, project.id)

      agent_audit_fixture(owner_scope, project, "remote_mcp")

      assert Alplus.Audit.agent_connected?(org.id, project.id)
    end

    test "agent_connected?/2 accepts a webmcp handshake" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      project = project_fixture(owner_scope, org)

      agent_audit_fixture(owner_scope, project, "webmcp")

      assert Alplus.Audit.agent_connected?(org.id, project.id)
    end

    test "agent_connected?/2 ignores denied, non-agent and non-MCP rows" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      project = project_fixture(owner_scope, org)

      audit_row(owner_scope, project, %{outcome: "denied"})
      audit_row(owner_scope, project, %{actor_kind: "user"})
      audit_row(owner_scope, project, %{transport: "session"})

      refute Alplus.Audit.agent_connected?(org.id, project.id)
    end

    test "agent_connected?/2 is bounded by both org and project" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      connected = project_fixture(owner_scope, org)
      other = project_fixture(owner_scope, org)
      {foreign_org, _foreign_scope} = org_fixture(scope_fixture())

      agent_audit_fixture(owner_scope, connected, "remote_mcp")

      assert Alplus.Audit.agent_connected?(org.id, connected.id)
      refute Alplus.Audit.agent_connected?(org.id, other.id)
      refute Alplus.Audit.agent_connected?(foreign_org.id, connected.id)
    end

    test "agent_connected_project_ids/2 returns only the connected ids in the requested set" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      connected = project_fixture(owner_scope, org)
      disconnected = project_fixture(owner_scope, org)

      agent_audit_fixture(owner_scope, connected, "remote_mcp")
      agent_audit_fixture(owner_scope, connected, "webmcp")

      assert MapSet.new([connected.id]) ==
               Alplus.Audit.agent_connected_project_ids(org.id, [connected.id, disconnected.id])

      assert MapSet.new() == Alplus.Audit.agent_connected_project_ids(org.id, [])
    end

    test "agent_connected_project_ids/2 never leaks another org's connected project" do
      {org, owner_scope} = org_fixture(scope_fixture())
      mine = project_fixture(owner_scope, org)

      {foreign_org, foreign_scope} = org_fixture(scope_fixture())
      theirs = project_fixture(foreign_scope, foreign_org)

      agent_audit_fixture(owner_scope, mine, "remote_mcp")
      agent_audit_fixture(foreign_scope, theirs, "remote_mcp")

      assert MapSet.new([mine.id]) ==
               Alplus.Audit.agent_connected_project_ids(org.id, [mine.id, theirs.id])
    end

    test "a member reads the same connection answer as the owner" do
      {org, owner_scope} = org_fixture(scope_fixture())
      project = project_fixture(owner_scope, org)
      member_scope = member_fixture(owner_scope, org, user_fixture(), "member")

      agent_audit_fixture(owner_scope, project, "remote_mcp")

      # The AuditLog read policy admits owners and admins only, so the
      # predicate must not depend on the reader.
      assert {:ok, []} =
               AuditLog
               |> Ash.Query.filter(org_id == ^org.id)
               |> Ash.read(actor: member_scope)

      assert Alplus.Audit.agent_connected?(org.id, project.id)

      assert MapSet.new([project.id]) ==
               Alplus.Audit.agent_connected_project_ids(org.id, [project.id])
    end
  end
end
