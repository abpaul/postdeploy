defmodule Alplus.Accounts.SignupGateTest do
  use Alplus.DataCase, async: false

  alias Alplus.Accounts.User

  @valid_attrs %{
    email: "gate-#{System.unique_integer([:positive])}@example.com",
    password: "supersecret1",
    password_confirmation: "supersecret1",
    turnstile_token: "test-token"
  }

  setup do
    original = Application.get_env(:alplus, :signups_enabled?)
    on_exit(fn -> Application.put_env(:alplus, :signups_enabled?, original) end)
    :ok
  end

  test "registration succeeds when signups are enabled" do
    Application.put_env(:alplus, :signups_enabled?, true)

    assert {:ok, %User{}} =
             Ash.create(User, @valid_attrs, action: :register_with_password, authorize?: false)
  end

  test "registration fails with a clear error when signups are disabled" do
    Application.put_env(:alplus, :signups_enabled?, false)

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Ash.create(User, @valid_attrs, action: :register_with_password, authorize?: false)

    assert Enum.any?(errors, &(&1.message =~ "Sign-ups are currently disabled"))
  end
end
