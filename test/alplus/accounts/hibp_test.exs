defmodule Alplus.Accounts.Hibp.ClientTest do
  use Alplus.DataCase, async: true

  alias Alplus.Accounts.{Hibp.Client, User}

  defp attrs(password) do
    %{
      email: "hibp-#{System.unique_integer([:positive])}@example.com",
      password: password,
      password_confirmation: password,
      turnstile_token: "test-token"
    }
  end

  # SHA-1("a-str0ng-passphrase") = 3F9A2A1B... — we only need a stable
  # value; compute the prefix/suffix the client will request so the stub
  # can answer for the exact password used below.
  defp hash_parts(password) do
    <<prefix::binary-size(5), suffix::binary-size(35)>> =
      :sha |> :crypto.hash(password) |> Base.encode16(case: :upper)

    {prefix, suffix}
  end

  test "pwned?/1 sends only the SHA-1 range prefix, never the password" do
    password = "a-str0ng-passphrase"
    {_prefix, suffix} = hash_parts(password)

    Req.Test.stub(Client, fn conn ->
      assert conn.method == "GET"
      refute conn.request_path =~ password
      Req.Test.text(conn, "#{suffix}:42\r\nAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:1\r\n")
    end)

    assert {:ok, true} = Client.pwned?(password)
  end

  test "pwned?/1 returns false when the suffix isn't in the response" do
    Req.Test.stub(Client, fn conn ->
      Req.Test.text(conn, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:1\r\n")
    end)

    assert {:ok, false} = Client.pwned?("a-str0ng-passphrase")
  end

  test "registration rejects a breached password" do
    password = "a-str0ng-passphrase"
    {_prefix, suffix} = hash_parts(password)

    Req.Test.stub(Client, fn conn ->
      Req.Test.text(conn, "#{suffix}:99999\r\n")
    end)

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Ash.create(User, attrs(password), action: :register_with_password, authorize?: false)

    assert Enum.any?(errors, &(&1.field == :password and &1.message =~ "data breach"))
  end

  test "registration fails closed (rejects the password) when HIBP is unreachable" do
    Req.Test.stub(Client, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Ash.create(User, attrs("a-str0ng-passphrase"),
               action: :register_with_password,
               authorize?: false
             )

    assert Enum.any?(errors, &(&1.field == :password and &1.message =~ "could not be checked"))
  end

  test "fail-open configuration accepts the password when HIBP is unreachable" do
    original = Application.get_env(:alplus, :hibp_fail_closed?)
    Application.put_env(:alplus, :hibp_fail_closed?, false)
    on_exit(fn -> Application.put_env(:alplus, :hibp_fail_closed?, original) end)

    Req.Test.stub(Client, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:ok, %User{}} =
             Ash.create(User, attrs("a-str0ng-passphrase"),
               action: :register_with_password,
               authorize?: false
             )
  end
end
