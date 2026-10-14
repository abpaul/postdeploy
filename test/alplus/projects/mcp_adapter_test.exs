defmodule Alplus.Projects.McpAdapterTest do
  @moduledoc """
  Creating a project through MCP.

  A project is the tenant boundary, so this tool decides what an agent can
  bring into existence. Every test here asks one question: can it reach past
  what the person consented to, or past what they pay for.
  """

  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Billing.Package
  alias Alplus.Mcp.{Dispatch, Principal}

  setup do
    {org, owner_scope} = org_fixture(scope_fixture())
    subscribed_fixture(org)

    %{org: org, scope: owner_scope}
  end

  defp principal(org, scope, opts \\ []) do
    %Principal{
      grant_id: Alplus.Id.generate(:mcp_oauth_grant),
      org_id: org.id,
      project_id: Keyword.get(opts, :project_id),
      user_id: scope.user_id,
      scopes: Keyword.get(opts, :scopes, Alplus.Mcp.Scope.all()),
      scope_mode: Keyword.get(opts, :scope_mode, :organization),
      source: :oauth,
      correlation_id: Alplus.Id.generate(:request)
    }
  end

  defp create(principal, name) do
    Dispatch.call(
      "projects.create",
      %{"name" => name, "idempotency_key" => Alplus.Id.generate(:request)},
      principal
    )
  end

  describe "creating a project" do
    test "returns the handle every other tool takes", context do
      assert {:ok, %{project: project}} =
               create(principal(context.org, context.scope), "checkout-service")

      assert project.name == "checkout-service"
      assert String.starts_with?(project.handle, "project_")
      assert is_binary(project.public_token)

      # The handle is immediately usable as a project_handle elsewhere.
      assert {:ok, _result} =
               Dispatch.call(
                 "analytics.overview",
                 %{"project_handle" => project.handle},
                 principal(context.org, context.scope)
               )
    end

    test "lists straight after creating", context do
      assert {:ok, %{project: created}} =
               create(principal(context.org, context.scope), "new-service")

      assert {:ok, %{projects: projects}} =
               Dispatch.call("projects.list", %{}, principal(context.org, context.scope))

      assert created.handle in Enum.map(projects, & &1.handle)
    end

    test "refuses a name that is only whitespace", context do
      assert {:error, error} = create(principal(context.org, context.scope), "   ")
      assert error.code == :invalid_argument
    end

    test "needs an idempotency key, like every other mutation", context do
      assert {:error, error} =
               Dispatch.call(
                 "projects.create",
                 %{"name" => "no-key"},
                 principal(context.org, context.scope)
               )

      assert error.code == :missing_idempotency_key
    end

    test "creates once when the same idempotency key is replayed", context do
      args = %{"name" => "replayed", "idempotency_key" => "key-replayed-once"}
      principal = principal(context.org, context.scope)

      assert {:ok, %{project: first}} = Dispatch.call("projects.create", args, principal)
      assert {:ok, %{project: second}} = Dispatch.call("projects.create", args, principal)

      assert first.handle == second.handle
    end
  end

  describe "what it cannot do" do
    test "refuses a connection pinned to one project", context do
      project = project_fixture(context.scope, context.org)

      pinned =
        principal(context.org, context.scope, scope_mode: :project, project_id: project.id)

      assert {:error, error} = create(pinned, "sneaky")
      assert error.code == :not_found
    end

    test "refuses a caller without the projects:write scope", context do
      reader = principal(context.org, context.scope, scopes: ["projects:read"])

      assert {:error, error} = create(reader, "read-only")
      assert error.code == :insufficient_scope
    end

    test "refuses once the organization has no project slots left", context do
      limit = Package.limit(:projects)
      for index <- 1..limit, do: project_fixture(context.scope, context.org, %{name: "p#{index}"})

      assert {:error, error} = create(principal(context.org, context.scope), "one-too-many")
      assert error.code == :resource_exhausted
    end

    test "refuses when the organization has lost access", context do
      Alplus.Repo.query!("UPDATE organizations SET trial_ends_at = $1 WHERE id = $2", [
        ~U[2000-01-01 00:00:00.000000Z],
        context.org.id
      ])

      Alplus.Repo.query!(
        "UPDATE organizations SET plan_status = 'canceled' WHERE id = $1",
        [context.org.id]
      )

      assert {:error, error} = create(principal(context.org, context.scope), "unpaid")
      assert error.code == :plan_inactive
    end

    test "creates in the granted organization, never another", context do
      {other_org, _other_scope} = org_fixture(scope_fixture())
      subscribed_fixture(other_org)

      # The principal names the other organization, but its user is not a
      # member there, so the create policy refuses.
      trespasser = principal(other_org, context.scope)

      assert {:error, _error} = create(trespasser, "trespass")

      assert Alplus.Repo.query!("SELECT count(*) FROM projects WHERE org_id = $1", [other_org.id]).rows ==
               [[0]]
    end

    test "a member without owner or admin role cannot create", context do
      member_user = user_fixture()
      member_scope = member_fixture(context.scope, context.org, member_user, "member")

      assert {:error, _error} = create(principal(context.org, member_scope), "by-a-member")
    end
  end
end
