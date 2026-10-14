defmodule Alplus.Orgs.Invitation.Changes.GenerateToken do
  @moduledoc """
  Generates a fresh raw invitation token, stores only its hash, resets the
  7-day expiry, and returns the token once via the `:token` action
  metadata. Used by both `:invite` and `:resend`.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    {token, hash} = Alplus.Security.BearerToken.generate()

    changeset
    |> Ash.Changeset.force_change_attribute(:token_hash, hash)
    |> Ash.Changeset.force_change_attribute(
      :expires_at,
      DateTime.add(DateTime.utc_now(), Alplus.Orgs.Invitation.expiry_seconds(), :second)
    )
    |> Ash.Changeset.after_action(fn _changeset, invitation ->
      {:ok, Ash.Resource.put_metadata(invitation, :token, token)}
    end)
  end
end
