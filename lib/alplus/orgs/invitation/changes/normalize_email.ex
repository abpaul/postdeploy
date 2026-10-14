defmodule Alplus.Orgs.Invitation.Changes.NormalizeEmail do
  @moduledoc """
  Trims and downcases the `:email` argument before it is stored, matching
  the `email = lower(btrim(email))` database constraint.

  A missing `:email` passes through untouched: `AshPhoenix.Form.for_create/3`
  builds an initial changeset before any params exist (e.g. an empty
  invite form on first render), so this runs with no argument set. The
  action's own `allow_nil? false` on `:email` is what rejects a truly
  missing value at submit time.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_argument(changeset, :email) do
      nil ->
        changeset

      email ->
        Ash.Changeset.change_attribute(
          changeset,
          :email,
          email |> String.trim() |> String.downcase()
        )
    end
  end
end
