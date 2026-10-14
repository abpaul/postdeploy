defmodule Alplus.AuthorizationMatrixTest do
  @moduledoc """
  Table-driven authorization matrix over the dashboard's mutating actions.

  Each pillar's LiveView test already proves a member cannot trigger its
  mutation by forging the event (the control-hidden + event-rejected
  convention). What none of them proves together is that *every* mutation
  agrees on the owner/admin/member split, and that admin — rarely exercised
  directly — is actually let through where the UI assumes it is.

  This hits the real Ash policy (or, for billing, the real authorization
  function) directly: the highest seam that proves the rule itself, not a
  page that merely reflects it (docs/BUILD.md §4, issue #8 Implementation
  Decisions).
  """

  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Measure.Goal
  alias Alplus.Monitoring.Monitor
  alias Alplus.Observe.Issue
  alias Alplus.Scope

  @roles ~w(owner admin member)

  # name => allowed roles. Any role not listed must be rejected.
  @matrix %{
    "project create" => ~w(owner admin),
    "project archive" => ~w(owner admin),
    "source create" => ~w(owner admin),
    "source rotate" => ~w(owner admin),
    "source revoke" => ~w(owner admin),
    "member invite" => ~w(owner admin),
    "member role-change" => ~w(owner admin),
    "member remove" => ~w(owner admin),
    "goal create" => ~w(owner admin),
    "goal delete" => ~w(owner admin),
    "issue resolve" => ~w(owner admin),
    "issue reopen" => ~w(owner admin),
    "monitor pause" => ~w(owner admin),
    "billing checkout" => ~w(owner)
  }

  test "the matrix covers exactly the release-blocking dashboard mutations" do
    expected =
      MapSet.new([
        "project create",
        "project archive",
        "source create",
        "source rotate",
        "source revoke",
        "member invite",
        "member role-change",
        "member remove",
        "goal create",
        "goal delete",
        "issue resolve",
        "issue reopen",
        "monitor pause",
        "billing checkout"
      ])

    assert MapSet.new(Map.keys(@matrix)) == expected
  end

  setup do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Scope.for_user(owner.id))

    admin_user = user_fixture()
    admin_scope = member_fixture(owner_scope, org, admin_user, "admin")

    member_user = user_fixture()
    member_scope = member_fixture(owner_scope, org, member_user, "member")

    project = project_fixture(owner_scope, org)

    scopes = %{"owner" => owner_scope, "admin" => admin_scope, "member" => member_scope}

    %{
      org: org,
      project: project,
      owner_scope: owner_scope,
      admin_scope: admin_scope,
      member_scope: member_scope,
      scopes: scopes
    }
  end

  for {action_name, allowed_roles} <- @matrix, role <- @roles do
    allowed? = role in allowed_roles

    describe "#{action_name} as #{role}" do
      test if(allowed?, do: "succeeds", else: "is rejected by the real policy"),
           %{scopes: scopes} = ctx do
        actor = Map.fetch!(scopes, unquote(role))
        result = run_action(unquote(action_name), ctx, actor)

        if unquote(allowed?) do
          # Ash destroy actions return a bare `:ok` unless the action opts
          # into `return_destroyed?: true`; create/update return `{:ok, _}`.
          assert result == :ok or match?({:ok, _}, result),
                 "expected #{unquote(role)} to be allowed, got #{inspect(result)}"
        else
          # Billing's owner check is a plain guard function, not an Ash
          # policy (lib/alplus/billing/checkout.ex) — both shapes deny.
          assert match?({:error, _}, result),
                 "expected #{unquote(role)} to be denied, got #{inspect(result)}"
        end
      end
    end
  end

  defp project_scope(scope, project), do: Scope.put_project(scope, project.id)

  defp run_action("project create", %{org: org}, actor) do
    Alplus.Projects.create_project(
      %{
        org_id: org.id,
        name: "Matrix project",
        slug: "matrix-#{System.unique_integer([:positive])}"
      },
      actor: actor
    )
  end

  defp run_action("project archive", %{org: org, owner_scope: owner_scope}, actor) do
    {:ok, target} =
      Alplus.Projects.create_project(
        %{
          org_id: org.id,
          name: "To archive",
          slug: "to-archive-#{System.unique_integer([:positive])}"
        },
        actor: owner_scope
      )

    Alplus.Projects.archive_project(target, actor: actor)
  end

  defp run_action("source create", %{org: org, project: project}, actor) do
    Alplus.Sources.create_source(
      %{
        org_id: org.id,
        project_id: project.id,
        type: :observe,
        environment: "production",
        name: "Matrix source"
      },
      actor: project_scope(actor, project)
    )
  end

  defp run_action(
         "source rotate",
         %{org: org, project: project, owner_scope: owner_scope},
         actor
       ) do
    {source, _secret} = source_fixture(owner_scope, org, project)
    Alplus.Sources.rotate_source(source, 86_400, actor: project_scope(actor, project))
  end

  defp run_action(
         "source revoke",
         %{org: org, project: project, owner_scope: owner_scope},
         actor
       ) do
    {source, _secret} = source_fixture(owner_scope, org, project)
    Alplus.Sources.revoke_source(source, actor: project_scope(actor, project))
  end

  defp run_action("member invite", %{org: org}, actor) do
    Alplus.Orgs.invite_member(
      %{
        org_id: org.id,
        email: "matrix-#{System.unique_integer([:positive])}@example.com",
        role: "member"
      },
      actor: actor
    )
  end

  defp run_action("member role-change", %{org: org, owner_scope: owner_scope}, actor) do
    target_user = user_fixture()
    _target_scope = member_fixture(owner_scope, org, target_user, "member")
    target_membership = fetch_membership!(org, target_user, owner_scope)

    Alplus.Orgs.change_member_role(target_membership, %{role: "admin"}, actor: actor)
  end

  defp run_action("member remove", %{org: org, owner_scope: owner_scope}, actor) do
    target_user = user_fixture()
    _target_scope = member_fixture(owner_scope, org, target_user, "member")
    target_membership = fetch_membership!(org, target_user, owner_scope)

    Alplus.Orgs.remove_member(target_membership, actor: actor)
  end

  defp run_action("goal create", %{org: org, project: project}, actor) do
    Ash.create(
      Goal,
      %{
        org_id: org.id,
        project_id: project.id,
        name: "Matrix goal",
        kind: "pageview",
        path: "/pricing"
      },
      action: :create,
      actor: project_scope(actor, project)
    )
  end

  defp run_action("goal delete", %{org: org, project: project, owner_scope: owner_scope}, actor) do
    target =
      Ash.create!(
        Goal,
        %{
          org_id: org.id,
          project_id: project.id,
          name: "To delete",
          kind: "pageview",
          path: "/pricing"
        },
        action: :create,
        actor: project_scope(owner_scope, project)
      )

    Ash.destroy(target, action: :destroy, actor: project_scope(actor, project))
  end

  defp run_action("issue resolve", %{org: org, project: project}, actor) do
    issue = issue_fixture(org, project)
    Ash.update(issue, %{}, action: :resolve, actor: project_scope(actor, project))
  end

  defp run_action("issue reopen", %{org: org, project: project, owner_scope: owner_scope}, actor) do
    issue = issue_fixture(org, project)

    resolved =
      Ash.update!(issue, %{}, action: :resolve, actor: project_scope(owner_scope, project))

    Ash.update(resolved, %{}, action: :reopen, actor: project_scope(actor, project))
  end

  defp run_action("monitor pause", %{org: org, project: project, owner_scope: owner_scope}, actor) do
    monitor =
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "http", name: "Matrix monitor"},
        action: :create,
        actor: project_scope(owner_scope, project)
      )

    Ash.update(monitor, %{status: "paused"},
      action: :update,
      actor: project_scope(actor, project)
    )
  end

  defp run_action("billing checkout", %{org: org}, actor) do
    Alplus.Billing.Checkout.create_checkout(actor, org.id)
  end

  defp fetch_membership!(org, user, owner_scope) do
    Alplus.Orgs.list_memberships_for_org!(org.id, actor: owner_scope)
    |> Enum.find(&(&1.user_id == user.id))
  end

  defp issue_fixture(org, project) do
    now = DateTime.utc_now()

    Ash.create!(
      Issue,
      %{
        org_id: org.id,
        project_id: project.id,
        environment: "production",
        fingerprint: "sha256:" <> String.duplicate("c", 64),
        level: "error",
        title: "Matrix issue",
        first_seen_at: now,
        last_seen_at: now
      },
      action: :record,
      authorize?: false
    )
  end
end
