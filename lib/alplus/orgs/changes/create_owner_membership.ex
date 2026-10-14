defmodule Alplus.Orgs.Changes.CreateOwnerMembership do
  @moduledoc """
  After an org is created, creates its owner membership for the creating
  actor in the same transaction (ARCHITECTURE.md §4: "exactly one owner").

  Runs with `authorize?: false` because the actor has no membership yet —
  authorization for org creation already happened on the outer `:create`
  action; this is the system completing that action's invariant, not a
  second user-facing mutation.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, organization ->
      actor = context.actor

      case Ash.create(Alplus.Orgs.Membership, %{org_id: organization.id, user_id: actor.user_id},
             action: :create_owner,
             authorize?: false
           ) do
        {:ok, _membership} -> {:ok, organization}
        {:error, error} -> {:error, error}
      end
    end)
  end
end
