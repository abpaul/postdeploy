defmodule Alplus.Orgs.Invitation.Changes.SendInvitationEmail do
  @moduledoc """
  Emails the accept link during `:invite`/`:resend`. The job is inserted only
  for a successful domain result, after the owning transaction completes.
  Delivery and retry belong to `Alplus.Mailer.Worker`.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      case result do
        {:ok, invitation} ->
          token = Ash.Resource.get_metadata(invitation, :token)
          Alplus.Orgs.Invitation.Senders.SendInvitationEmail.send(invitation, token)
          result

        _ ->
          result
      end
    end)
  end
end
