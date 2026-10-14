defmodule Alplus.Mcp.IdempotencyValidationSourceAdapter do
  @moduledoc """
  A read_write adapter that mirrors `measure.create_source`: it writes a
  `Alplus.Sources.Source` row and then returns a result validated against
  `output_schema`. The output mode is controlled by an application env flag
  so a test can simulate a buggy adapter, then "fix" it and retry the exact
  same idempotency key and arguments.
  """
  @behaviour Alplus.Mcp.Adapter

  alias Alplus.Mcp.{Principal, Tenancy}
  alias Alplus.Sources.Source

  @impl true
  def prefix, do: "sourcetest"

  @impl true
  def tools do
    [
      %Alplus.Mcp.Tool{
        name: "sourcetest.create_source",
        title: "Create a source (test)",
        description: "Writes a Source and returns it, shaped like measure.create_source",
        input_schema: %{"type" => "object"},
        output_schema: %{
          "type" => "object",
          "properties" => %{
            "source" => %{"type" => "object"},
            "secret" => %{"type" => "string"}
          },
          "required" => ["source", "secret"]
        },
        annotations: %{},
        cost_weight: 1,
        requires_access: :read_write
      }
    ]
  end

  @impl true
  def call("sourcetest.create_source", args, %Principal{} = principal) do
    with {:ok, scope} <- Tenancy.resolve(principal, args["project_handle"]) do
      source =
        Ash.create!(
          Source,
          %{
            org_id: scope.org_id,
            project_id: scope.project_id,
            type: :observe,
            environment: "production",
            name: args["name"]
          },
          action: :create,
          actor: scope
        )

      case Application.get_env(:alplus, :sourcetest_output_mode, :valid) do
        :invalid ->
          # Deliberately omits the required "secret" field.
          {:ok, %{"source" => %{"handle" => source.id}}}

        :valid ->
          {:ok,
           %{
             "source" => %{"handle" => source.id},
             "secret" => Ash.Resource.get_metadata(source, :secret) || "test-secret"
           }}
      end
    end
  end
end

defmodule Alplus.Mcp.IdempotencyOutputValidationTest do
  use Alplus.DataCase, async: false
  require Ash.Query

  import Alplus.OrgsFixtures

  alias Alplus.Mcp.{IdempotencyRecord, Principal}
  alias Alplus.Mcp.IdempotencyValidationSourceAdapter, as: SourceAdapter
  alias Alplus.Sources.Source

  setup do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org, %{slug: "idem-validation"})

    previous_adapters = Application.get_env(:alplus, :mcp_adapters)
    previous_mode = Application.get_env(:alplus, :sourcetest_output_mode)
    Application.put_env(:alplus, :mcp_adapters, [SourceAdapter])
    Application.put_env(:alplus, :sourcetest_output_mode, :valid)

    on_exit(fn ->
      Application.put_env(:alplus, :mcp_adapters, previous_adapters)

      if is_nil(previous_mode) do
        Application.delete_env(:alplus, :sourcetest_output_mode)
      else
        Application.put_env(:alplus, :sourcetest_output_mode, previous_mode)
      end
    end)

    principal =
      owner_scope
      |> Alplus.Scope.put_project(project.id)
      |> Principal.from_session()

    %{org: org, project: project, principal: principal}
  end

  defp args(project, key, name) do
    %{
      "idempotency_key" => key,
      "project_handle" => project.id,
      "name" => name
    }
  end

  defp idempotency_record(org, key) do
    IdempotencyRecord
    |> Ash.Query.filter(
      org_id == ^org.id and tool == "sourcetest.create_source" and idempotency_key == ^key
    )
    |> Ash.read_one(authorize?: false)
  end

  defp sources_named(project, name) do
    Source
    |> Ash.Query.filter(project_id == ^project.id and name == ^name)
    |> Ash.read!(authorize?: false)
  end

  test "an invalid result rolls back the write and leaves no cached record", %{
    org: org,
    project: project,
    principal: principal
  } do
    Application.put_env(:alplus, :sourcetest_output_mode, :invalid)

    args = args(project, "rollback-key", "rollback-source")

    assert {:error, %{code: :invalid_result}} =
             Alplus.Mcp.Dispatch.call("sourcetest.create_source", args, principal)

    assert {:ok, nil} = idempotency_record(org, "rollback-key")
    assert sources_named(project, "rollback-source") == []
  end

  test "retrying the same key and arguments succeeds once the adapter is fixed", %{
    org: org,
    project: project,
    principal: principal
  } do
    Application.put_env(:alplus, :sourcetest_output_mode, :invalid)
    args = args(project, "retry-key", "retry-source")

    assert {:error, %{code: :invalid_result}} =
             Alplus.Mcp.Dispatch.call("sourcetest.create_source", args, principal)

    assert {:ok, nil} = idempotency_record(org, "retry-key")
    assert sources_named(project, "retry-source") == []

    Application.put_env(:alplus, :sourcetest_output_mode, :valid)

    assert {:ok, %{"secret" => secret}} =
             Alplus.Mcp.Dispatch.call("sourcetest.create_source", args, principal)

    assert is_binary(secret) and secret != ""
    assert {:ok, %IdempotencyRecord{}} = idempotency_record(org, "retry-key")
    assert [%Source{}] = sources_named(project, "retry-source")
  end

  test "a valid result is written once and replayed on retry with the same key", %{
    project: project,
    principal: principal
  } do
    args = args(project, "happy-key", "happy-source")

    assert {:ok, first} = Alplus.Mcp.Dispatch.call("sourcetest.create_source", args, principal)
    assert {:ok, second} = Alplus.Mcp.Dispatch.call("sourcetest.create_source", args, principal)

    assert first == second
    assert [%Source{}] = sources_named(project, "happy-source")
  end
end
