defmodule Alplus.Mcp.ConfirmationTest do
  use ExUnit.Case, async: true

  alias Alplus.Mcp.Confirmation

  test "stores arguments and results through private AshCloak ciphertext attributes" do
    arguments = Ash.Resource.Info.attribute(Confirmation, :encrypted_arguments)
    result = Ash.Resource.Info.attribute(Confirmation, :encrypted_result)
    arguments_calculation = Ash.Resource.Info.calculation(Confirmation, :arguments)
    result_calculation = Ash.Resource.Info.calculation(Confirmation, :result)

    assert arguments.type == Ash.Type.Binary
    assert result.type == Ash.Type.Binary
    refute arguments.public?
    refute result.public?
    assert arguments.sensitive?
    assert result.sensitive?
    refute arguments_calculation.filterable?
    refute result_calculation.filterable?
    assert arguments_calculation.sensitive?
    assert result_calculation.sensitive?
  end

  test "has a closed confirmation state set" do
    statement =
      Confirmation
      |> AshPostgres.DataLayer.Info.custom_statements()
      |> Enum.find(&(&1.name == :confirmation_constraints))

    assert statement
    assert statement.up =~ "pending"
    assert statement.up =~ "approved"
    assert statement.up =~ "rejected"
    assert statement.up =~ "expired"
    assert statement.up =~ "failed"
  end
end
