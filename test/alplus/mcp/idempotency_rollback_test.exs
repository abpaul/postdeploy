defmodule Alplus.Mcp.IdempotencyRollbackTest do
  @moduledoc """
  A rollback inside `Idempotency.run/5` must reach the caller as the error the
  code wrote, with its `code` and `details` intact. `Repo.rollback/1` used to
  normalize the struct into `Ash.Error.Unknown`, which reported every failure
  below as a bare `invalid_argument` with no message and no details.
  """
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Mcp.{Error, Idempotency, Principal}
  alias Alplus.Repo

  setup do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org, %{slug: "idem-rollback"})

    principal =
      owner_scope
      |> Alplus.Scope.put_project(project.id)
      |> Principal.from_session()

    %{org: org, principal: principal}
  end

  defp args(key), do: %{"idempotency_key" => key, "name" => "rollback-probe"}

  defp ok_result, do: {:ok, %{"secret" => "s3cret"}}

  test "an unreadable cached result reports why, not a bare invalid argument", %{
    org: org,
    principal: principal
  } do
    args = args("unreadable-key")

    assert {:ok, _result} = Idempotency.run(principal, "probe.create", args, &ok_result/0)

    # Corrupt the stored ciphertext so decode_result/1 cannot read it back.
    Repo.query!(
      "UPDATE mcp_idempotency_records SET result = $1 WHERE org_id = $2",
      [%{"__alplus_mcp_result__" => "v2:not-base64!"}, org.id]
    )

    assert {:error, %Error{} = error} =
             Idempotency.run(principal, "probe.create", args, &ok_result/0)

    assert error.code == :invalid_argument
    assert error.message == "The cached mutation result is unreadable"
  end

  test "an invalid result reports the offending field", %{principal: principal} do
    validator = fn _result -> {:error, "secret"} end

    assert {:error, %Error{} = error} =
             Idempotency.run(
               principal,
               "probe.create",
               args("invalid-result-key"),
               &ok_result/0,
               validator
             )

    assert error.code == :invalid_result
    assert error.details == %{field: "secret"}
  end

  test "a result that cannot be stored reports why, not a bare invalid argument", %{
    principal: principal
  } do
    # `tool` caps at 120 characters, so the record insert fails after the
    # mutation ran and the result was encrypted.
    oversized_tool = String.duplicate("p", 121)

    assert {:error, %Error{} = error} =
             Idempotency.run(principal, oversized_tool, args("unstorable-key"), &ok_result/0)

    assert error.code == :invalid_argument
    assert error.message == "The mutation result could not be stored"
  end

  test "a result that cannot be encrypted reports why, not a bare invalid argument", %{
    principal: principal
  } do
    # Cloak refuses to encrypt when the vault holds no cipher. The vault keeps
    # its config in an ETS table it alone may write, so drive it through the
    # vault process. This test is synchronous, so no other test runs meanwhile.
    vault = Alplus.NotificationsVault
    config = :sys.get_state(vault)

    on_exit(fn ->
      :sys.replace_state(vault, fn _ -> config end)
      GenServer.call(vault, :save_config)
    end)

    :sys.replace_state(vault, fn _ -> Keyword.put(config, :ciphers, []) end)
    GenServer.call(vault, :save_config)

    assert {:error, %Error{} = error} =
             Idempotency.run(principal, "probe.create", args("unencryptable-key"), &ok_result/0)

    assert error.code == :invalid_argument
    assert error.message == "The mutation result could not be encrypted"
  end

  test "a rollback leaves no cached record behind", %{org: org, principal: principal} do
    validator = fn _result -> {:error, "secret"} end

    assert {:error, %Error{code: :invalid_result}} =
             Idempotency.run(
               principal,
               "probe.create",
               args("no-leftovers-key"),
               &ok_result/0,
               validator
             )

    assert Repo.query!("SELECT count(*) FROM mcp_idempotency_records WHERE org_id = $1", [org.id]).rows ==
             [[0]]
  end
end
