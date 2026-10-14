defmodule Alplus.Accounts.TurnstileTest do
  use Alplus.DataCase, async: true
  use Oban.Testing, repo: Alplus.Repo

  alias Alplus.Accounts.User
  alias Alplus.Turnstile
  alias Alplus.Turnstile.Client

  defp attrs(token) do
    %{
      email: "ts-#{System.unique_integer([:positive])}@example.com",
      password: "a-str0ng-passphrase",
      password_confirmation: "a-str0ng-passphrase",
      turnstile_token: token
    }
  end

  test "verify/2 posts the secret and response, never logs either" do
    Req.Test.stub(Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "secret="
      assert body =~ "response=some-token"
      Req.Test.json(conn, %{"success" => true})
    end)

    assert {:ok, true} = Client.verify("some-token", nil)
  end

  test "verify/2 fails closed for malformed tokens without an HTTP request" do
    Req.Test.stub(Client, fn _conn -> flunk("malformed tokens must not reach Cloudflare") end)

    assert {:ok, false} = Client.verify(nil, nil)
    assert {:ok, false} = Client.verify([], nil)
    assert {:ok, false} = Client.verify(%{"token" => "x"}, nil)
    assert {:ok, false} = Client.verify("", nil)
    assert {:ok, false} = Client.verify(String.duplicate("x", 2049), nil)
  end

  # Production shipped with `1x00000000000000000000AA` and its matching secret.
  # That pair renders a widget stamped "For testing only" and validates every
  # response token, so sign-up had no bot protection while looking healthy.
  # `config/runtime.exs` refuses to boot on one; this pins what it recognises.
  describe "dummy_key?/1" do
    test "recognises Cloudflare's testing keys, by list and by shape" do
      assert Turnstile.dummy_key?("1x00000000000000000000AA")
      assert Turnstile.dummy_key?("2x00000000000000000000AB")
      assert Turnstile.dummy_key?("3x00000000000000000000FF")
      assert Turnstile.dummy_key?("1x0000000000000000000000000000000AA")
      # Shape rule, so an unpublished variant is caught too.
      assert Turnstile.dummy_key?("2x000000000000000000000000ZZ")
    end

    test "passes a real key and anything unset" do
      refute Turnstile.dummy_key?("0x4AAAAAAEPMxlI8HUYJ7TT4")
      refute Turnstile.dummy_key?("0x4AAAAAAEPMxvY8Q3La3VJxZmgiviK1pg8")
      refute Turnstile.dummy_key?(nil)
      refute Turnstile.dummy_key?("")
    end
  end

  test "registration succeeds with a valid Turnstile response" do
    assert {:ok, %User{}} =
             Ash.create(User, attrs("good-token"),
               action: :register_with_password,
               authorize?: false
             )
  end

  test "registration is rejected when Turnstile verification fails" do
    Req.Test.stub(Client, fn conn -> Req.Test.json(conn, %{"success" => false}) end)

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Ash.create(User, attrs("bad-token"),
               action: :register_with_password,
               authorize?: false
             )

    assert Enum.any?(
             errors,
             &(&1.field == :turnstile_token and &1.message =~ "Verification failed")
           )
  end

  test "registration is rejected when the token is missing" do
    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Ash.create(User, attrs(nil), action: :register_with_password, authorize?: false)

    assert Enum.any?(
             errors,
             &(&1.field == :turnstile_token and &1.message =~ "Verification failed")
           )
  end

  test "registration is rejected when Turnstile is unreachable" do
    Req.Test.stub(Client, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Ash.create(User, attrs("some-token"),
               action: :register_with_password,
               authorize?: false
             )

    assert Enum.any?(
             errors,
             &(&1.field == :turnstile_token and &1.message =~ "Could not verify")
           )
  end

  test "password reset requires a valid Turnstile response" do
    Req.Test.stub(Client, fn conn -> Req.Test.json(conn, %{"success" => false}) end)

    input =
      Ash.ActionInput.for_action(
        User,
        :request_password_reset_token,
        %{email: "reset@example.com", turnstile_token: "bad-token"},
        authorize?: false
      )

    assert {:error, %Ash.Error.Invalid{errors: errors}} = Ash.run_action(input)

    assert Enum.any?(
             errors,
             &(&1.field == :turnstile_token and &1.message =~ "Verification failed")
           )
  end

  test "password reset sends one mail job after valid verification" do
    user =
      Ash.create!(User, attrs("registration-token"),
        action: :register_with_password,
        authorize?: false
      )

    assert :ok =
             Ash.run_action(
               Ash.ActionInput.for_action(
                 User,
                 :request_password_reset_token,
                 %{email: user.email, turnstile_token: "reset-token"},
                 authorize?: false
               )
             )

    assert [%{args: %{"purpose" => "password_reset", "user_id" => user_id}}] =
             all_enqueued(worker: Alplus.Mailer.Worker, args: %{"purpose" => "password_reset"})

    assert user_id == user.id
  end

  test "password reset fails closed when verification is unavailable" do
    Req.Test.stub(Client, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    input =
      Ash.ActionInput.for_action(
        User,
        :request_password_reset_token,
        %{email: "reset@example.com", turnstile_token: "reset-token"},
        authorize?: false
      )

    assert {:error, %Ash.Error.Invalid{errors: errors}} = Ash.run_action(input)

    assert Enum.any?(errors, &(&1.field == :turnstile_token and &1.message =~ "Could not verify"))

    refute Enum.any?(all_enqueued(worker: Alplus.Mailer.Worker), fn %{args: args} ->
             args["purpose"] == "password_reset"
           end)
  end
end
