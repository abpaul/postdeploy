defmodule Alplus.Accounts.ResendConfirmation do
  @moduledoc """
  Resends the new-user confirmation email (ARCHITECTURE.md §10) for the
  dashboard's "Confirm your email" banner.

  `confirm_new_user` is `confirm_on_update? false`, so there is no built-in
  action that re-triggers it — a profile update to `:email` would not
  re-send this link, only `Alplus.Accounts.User.Senders
  .SendEmailChangeConfirmationEmail`'s separate strategy. This regenerates
  confirmation token and hands it to the mailer queue, mirroring what
  `AshAuthentication.AddOn.Confirmation.ConfirmationHookChange` does after
  `:register_with_password`. No new Ash action and no new business rule apply.
  """

  alias AshAuthentication.AddOn.Confirmation
  alias Alplus.Accounts.User

  @spec resend(Ash.Resource.Record.t()) :: :ok | {:error, :already_confirmed | term()}
  def resend(%User{confirmed_at: %DateTime{}}), do: {:error, :already_confirmed}

  def resend(%User{} = user) do
    strategy = AshAuthentication.Info.strategy!(User, :confirm_new_user)
    changeset = Ash.Changeset.for_update(user, strategy.confirm_action_name, %{})

    case Confirmation.confirmation_token(strategy, changeset, user) do
      {:ok, token} ->
        {sender, send_opts} = strategy.sender
        sender.send(user, token, send_opts)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
