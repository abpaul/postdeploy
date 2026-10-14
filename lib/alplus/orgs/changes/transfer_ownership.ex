defmodule Alplus.Orgs.Changes.TransferOwnership do
  @moduledoc """
  Atomically transfers org ownership: demotes the current owner to `admin`,
  then promotes the target membership to `owner`, in that order and inside
  one transaction, so the DB's "exactly one owner" partial unique index
  never sees two owner rows at once (ARCHITECTURE.md §4).

  The demotion runs with `authorize?: false`: the outer `:promote_to_owner`
  policy already proved the actor is the current owner, which is the only
  fact needed to justify demoting themselves as part of the same transfer.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      target = changeset.data

      current_owner =
        Alplus.Orgs.Membership
        |> Ash.Query.filter(org_id == ^target.org_id and role == "owner" and id != ^target.id)
        |> Ash.read_one!(authorize?: false)

      if current_owner do
        Ash.update!(current_owner, %{}, action: :demote_from_owner, authorize?: false)
      end

      changeset
    end)
    |> Ash.Changeset.change_attribute(:role, "owner")
  end
end
