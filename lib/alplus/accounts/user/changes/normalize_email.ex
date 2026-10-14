defmodule Alplus.Accounts.User.Changes.NormalizeEmail do
  @moduledoc """
  Trims and downcases the `:email` attribute before it is stored, matching
  the `email = lower(btrim(email))` database constraint (mirrors
  `Alplus.Orgs.Invitation.Changes.NormalizeEmail`).

  Runs as a plain synchronous change, so by the time
  `AshAuthentication.AddOn.Confirmation.ConfirmationHookChange`'s
  `before_action` hook captures the pending email change (to email the new
  address and stage it for `:confirm_email_change`), it already sees the
  normalized value.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :email) do
      nil ->
        changeset

      email ->
        Ash.Changeset.change_attribute(
          changeset,
          :email,
          email |> to_string() |> String.trim() |> String.downcase()
        )
    end
  end
end
