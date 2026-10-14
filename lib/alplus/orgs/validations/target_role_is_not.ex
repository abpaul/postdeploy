defmodule Alplus.Orgs.Validations.TargetRoleIsNot do
  @moduledoc """
  Rejects the action if the record's *current* role matches `opts[:role]`.

  Used to keep the org owner's membership out of `:change_role` and
  `:destroy` — ownership only moves through `:promote_to_owner`
  (ARCHITECTURE.md §4: "atomic ownership transfer").
  """

  use Ash.Resource.Validation

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :role) do
      {:ok, role} when is_binary(role) -> {:ok, opts}
      _ -> {:error, "TargetRoleIsNot requires a :role option"}
    end
  end

  @impl true
  def validate(changeset, opts, _context) do
    if changeset.data.role == opts[:role] do
      {:error,
       field: :role,
       message: "cannot change or remove the %{role} membership this way",
       vars: [role: opts[:role]]}
    else
      :ok
    end
  end
end
