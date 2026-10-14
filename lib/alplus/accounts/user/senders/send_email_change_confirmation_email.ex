defmodule Alplus.Accounts.User.Senders.SendEmailChangeConfirmationEmail do
  @moduledoc """
  Sends the re-verification email for a profile email change
  (`:confirm_email_change`, `Alplus.Accounts.User`'s `:update_profile`
  action).

  The confirmation add-on's `inhibit_updates?` (default `true`) means the
  `:email` attribute on `user` (the after-action result passed in here) is
  still the *old*, unchanged address — the new one was staged, not
  persisted. The pending new address only lives in `opts[:changeset]`
  (`AshAuthentication.AddOn.Confirmation.confirmation_token/4`'s
  `original_changeset`), so this reads it from there, not from `user`.
  """

  use AshAuthentication.Sender
  use AlplusWeb, :verified_routes

  alias Alplus.Mail
  alias Alplus.Mailer.Worker

  @impl true
  def send(user, token, opts) do
    pending_email = pending_email(user, opts)

    Worker.enqueue!(%{
      "purpose" => "email_change",
      "record_id" => token_record_id(token),
      "user_id" => user.id,
      "token" => token,
      "pending_email" => to_string(pending_email)
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
  def build(user, token, opts) do
    Mail.build(
      to: to_string(pending_email(user, opts)),
      subject: "Confirm your new email address",
      heading: "Confirm your new email address",
      paragraphs: ["This address was set as the new email for an PostDeploy account."],
      action: {"Confirm new address", url(~p"/confirm_email_change/#{token}")},
      note: "The current address stays the login for that account until this is confirmed.",
      footer_note: "You received this because this address was entered as a new PostDeploy email."
    )
  end

  defp pending_email(user, opts) do
    case Keyword.fetch(opts, :pending_email) do
      {:ok, email} ->
        email

      :error ->
        case Keyword.fetch(opts, :changeset) do
          {:ok, changeset} -> Ash.Changeset.get_attribute(changeset, :email) || user.email
          :error -> user.email
        end
    end
  end
end
