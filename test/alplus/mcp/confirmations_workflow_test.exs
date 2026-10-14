defmodule Alplus.Mcp.ConfirmationWorkflowAdapter do
  @behaviour Alplus.Mcp.Adapter

  alias Alplus.Mcp.{Principal, ToolSpec}

  @impl true
  def prefix, do: "confirmation_test"

  @impl true
  def tools do
    [
      ToolSpec.mutation_tool(
        "confirmation_test.delete",
        "Delete a test resource",
        "Delete one test resource after confirmation.",
        ToolSpec.strict_object(
          %{
            "project_handle" => %{type: "string"},
            "idempotency_key" => %{type: "string"}
          },
          ["project_handle", "idempotency_key"]
        ),
        ToolSpec.strict_object(%{"deleted" => %{type: "boolean"}}, ["deleted"]),
        %{destructiveHint: true, idempotentHint: true}
      )
    ]
  end

  @impl true
  def call("confirmation_test.delete", arguments, %Principal{} = principal) do
    send(Application.fetch_env!(:alplus, :confirmation_test_pid), {
      :confirmation_executed,
      arguments,
      principal
    })

    {:ok, %{"deleted" => true}}
  end
end

defmodule Alplus.Mcp.ConfirmationsWorkflowTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures
  alias Alplus.Mcp.{Confirmations, Gateway, Principal}

  setup do
    original_adapters = Application.fetch_env!(:alplus, :mcp_adapters)

    Application.put_env(
      :alplus,
      :mcp_adapters,
      [Alplus.Mcp.ConfirmationWorkflowAdapter | original_adapters]
    )

    Application.put_env(:alplus, :confirmation_test_pid, self())

    on_exit(fn ->
      Application.put_env(:alplus, :mcp_adapters, original_adapters)
      Application.delete_env(:alplus, :confirmation_test_pid)
    end)

    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    scope = Alplus.Scope.put_project(owner_scope, project.id)

    principal = %Principal{
      grant_id: nil,
      org_id: org.id,
      project_id: project.id,
      user_id: owner.id,
      role: "owner",
      correlation_id: Alplus.Id.generate(:request),
      scopes: nil,
      access: :read_write,
      source: :session
    }

    %{org: org, project: project, scope: scope, principal: principal}
  end

  test "same principal, action, and idempotency key returns the existing confirmation", context do
    key = "same-key-#{System.unique_integer([:positive])}"

    assert {:ok, first} = Confirmations.request(context.principal, "projects.archive", %{}, key)
    assert {:ok, second} = Confirmations.request(context.principal, "projects.archive", %{}, key)
    assert first.id == second.id

    assert {:error, :idempotency_conflict} =
             Confirmations.request(
               context.principal,
               "projects.archive",
               %{"different" => true},
               key
             )
  end

  test "rejection is terminal and does not execute an action", context do
    key = "reject-key-#{System.unique_integer([:positive])}"

    assert {:ok, confirmation} =
             Confirmations.request(context.principal, "not.registered", %{}, key)

    assert {:ok, rejected} = Confirmations.reject(context.scope, confirmation.id)
    assert rejected.status == "rejected"
    assert {:ok, repeated} = Confirmations.reject(context.scope, confirmation.id)
    assert repeated.status == "rejected"
  end

  test "a foreign project cannot read or reject a confirmation", context do
    {foreign_org, foreign_scope} = org_fixture(Alplus.Scope.for_user(user_fixture().id))
    foreign_project = project_fixture(foreign_scope, foreign_org)
    foreign_scope = Alplus.Scope.put_project(foreign_scope, foreign_project.id)

    key = "foreign-key-#{System.unique_integer([:positive])}"

    assert {:ok, confirmation} =
             Confirmations.request(context.principal, "projects.archive", %{}, key)

    %Principal{} = principal = context.principal

    foreign_principal = %Principal{
      principal
      | org_id: foreign_org.id,
        project_id: foreign_project.id,
        user_id: foreign_scope.user_id
    }

    assert {:error, :not_found} = Confirmations.get(foreign_principal, confirmation.id)
    assert {:error, :not_found} = Confirmations.reject(foreign_scope, confirmation.id)
  end

  test "repeated approval executes a destructive action once", context do
    key = "approve-key-#{System.unique_integer([:positive])}"

    assert {:ok, %{"confirmation_id" => confirmation_id, "status" => "pending"}} =
             Gateway.call(
               "actions.destroy",
               %{
                 "action" => "confirmation_test.delete",
                 "arguments" => %{},
                 "idempotency_key" => key
               },
               context.principal
             )

    refute_receive {:confirmation_executed, _, _}

    assert {:ok, first} = Confirmations.approve(context.scope, confirmation_id)
    assert {:ok, second} = Confirmations.approve(context.scope, confirmation_id)
    assert first.status == "approved"
    assert second.status == "approved"

    assert_receive {:confirmation_executed, arguments, %Principal{} = principal}
    assert arguments["project_handle"] == context.project.id
    assert arguments["idempotency_key"] == key
    assert principal.user_id == context.principal.user_id
    refute_receive {:confirmation_executed, _, _}

    assert {:ok, completed} =
             Gateway.call(
               "confirmations.get",
               %{"confirmation_id" => confirmation_id},
               context.principal
             )

    assert completed["status"] == "approved"
    assert completed["result"] == %{"deleted" => true}
  end
end
