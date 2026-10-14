defmodule Alplus.Accounts.PasswordStrengthTest do
  use Alplus.DataCase, async: true

  alias Alplus.Accounts.User

  defp attrs(password) do
    %{
      email: "pw-#{System.unique_integer([:positive])}@example.com",
      password: password,
      password_confirmation: password,
      turnstile_token: "test-token"
    }
  end

  test "rejects a password shorter than the minimum length" do
    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Ash.create(User, attrs("short123"),
               action: :register_with_password,
               authorize?: false
             )

    assert Enum.any?(errors, &(&1.field == :password and &1.message =~ "at least"))
  end

  test "rejects a common weak password even at the minimum length" do
    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Ash.create(User, attrs("password1234"),
               action: :register_with_password,
               authorize?: false
             )

    assert Enum.any?(errors, &(&1.field == :password and &1.message =~ "too common"))
  end

  test "accepts a strong password" do
    assert {:ok, %User{}} =
             Ash.create(User, attrs("a-str0ng-passphrase"),
               action: :register_with_password,
               authorize?: false
             )
  end

  test "change_password rejects a weak new password" do
    user =
      Ash.create!(User, attrs("a-str0ng-passphrase"),
        action: :register_with_password,
        authorize?: false
      )

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Ash.update(
               user,
               %{
                 current_password: "a-str0ng-passphrase",
                 password: "password1234",
                 password_confirmation: "password1234"
               },
               action: :change_password,
               authorize?: false
             )

    assert Enum.any?(errors, &(&1.field == :password and &1.message =~ "too common"))
  end
end
