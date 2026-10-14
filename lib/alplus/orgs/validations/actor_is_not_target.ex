defmodule Alplus.Orgs.Validations.ActorIsNotTarget do
  @moduledoc """
  Rejects the action if the actor is acting on their own membership row.

  Enforces "no self role-change" (ARCHITECTURE.md §4) for `:change_role` and
  blocks a no-op self-transfer for `:promote_to_owner`.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, %{actor: %Alplus.Scope{user_id: actor_user_id}}) do
    if changeset.data.user_id == actor_user_id do
      {:error, field: :user_id, message: "cannot perform this action on your own membership"}
    else
      :ok
    end
  end

  def validate(_changeset, _opts, _context), do: :ok
end
