defmodule Alplus.Accounts.User.Senders.SendPasswordResetEmail do
  @moduledoc """
  Sends a password reset email
  """

  use AshAuthentication.Sender
  use AlplusWeb, :verified_routes

  alias Alplus.Mail
  alias Alplus.Mailer.Worker

  @impl true
  def send(user, token, _) do
    Worker.enqueue!(%{
      "purpose" => "password_reset",
      "record_id" => token_record_id(token),
      "user_id" => user.id,
      "token" => token
    })

    :ok
  end

  defp token_record_id(token) do
    case AshAuthentication.Jwt.peek(token) do
      {:ok, %{"jti" => jti}} -> jti
      _ -> raise ArgumentError, "authentication token has no persisted identity"
    end
  end

  @doc false
  def build(user, token, _) do
    Mail.build(
      to: to_string(user.email),
      subject: "Reset your password",
      paragraphs: ["Someone asked to reset the password for this PostDeploy account."],
      action: {"Reset password", url(~p"/password-reset/#{token}")},
      note: "If it wasn't you, ignore this email. Nothing has changed.",
      footer_note: "You received this because a password reset was requested for this address."
    )
  end
end
