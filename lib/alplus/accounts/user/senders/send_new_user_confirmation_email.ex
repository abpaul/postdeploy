defmodule Alplus.Accounts.User.Senders.SendNewUserConfirmationEmail do
  @moduledoc """
  Sends an email for a new user to confirm their email address.
  """

  use AshAuthentication.Sender
  use AlplusWeb, :verified_routes

  alias Alplus.Mail
  alias Alplus.Mailer.Worker

  @impl true
  def send(user, token, opts) do
    args = %{
      "purpose" => "user_confirmation",
      "record_id" => token_record_id(token),
      "user_id" => user.id,
      "token" => token
    }

    args =
      case opts[:confirmation_type] do
        :identity_link ->
          Map.merge(args, %{
            "confirmation_type" => "identity_link",
            "provider" => to_string(opts[:provider])
          })

        _ ->
          args
      end

    Worker.enqueue!(args)
    :ok
  end

  defp token_record_id(token) do
    case AshAuthentication.Jwt.peek(token) do
      {:ok, %{"jti" => jti}} -> jti
      _ -> raise ArgumentError, "authentication token has no persisted identity"
    end
  end

  @doc false
  def build(user, token, opts) do
    url = url(~p"/confirm_new_user/#{token}")

    [to: to_string(user.email)]
    |> Keyword.merge(message(url, opts))
    |> Mail.build()
  end

  # `opts[:confirmation_type]` is `:identity_link` when an OAuth2/OIDC
  # sign-in whose email matches this already-registered account is asking
  # to be linked (the strategy's `on_untrusted_email_match :confirm`).
  # Confirming grants that provider login access to this account, so make
  # the copy unambiguous about who is asking and what it does.
  defp message(url, opts) do
    case opts[:confirmation_type] do
      :identity_link -> identity_link(url, opts)
      _ -> confirmation(url)
    end
  end

  defp confirmation(url) do
    [
      subject: "Confirm your email address",
      heading: "Confirm your email address",
      paragraphs: ["Confirm this address to finish setting up your PostDeploy account."],
      action: {"Confirm email address", url},
      footer_note: "You received this because this address was used to sign up for PostDeploy."
    ]
  end

  defp identity_link(url, opts) do
    provider = opts[:provider]

    [
      subject: "Confirm linking your #{provider} login",
      heading: "Confirm linking your #{provider} login",
      paragraphs: [
        "Someone signed in with #{provider} using your email address and wants to link it to your PostDeploy account.",
        "Confirming lets that #{provider} login into this account."
      ],
      action: {"Link #{provider} login", url},
      note: "If it wasn't you, ignore this email. Nothing has changed.",
      footer_note: "You received this because a #{provider} login matched this address."
    ]
  end
end
