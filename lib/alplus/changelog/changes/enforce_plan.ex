defmodule Alplus.Changelog.Changes.EnforcePlan do
  @moduledoc """
  Refuses Changelog writes when the organization's plan is inactive.

  Reads stay open so an organization can inspect its content and resolve the
  billing problem that caused the write lock.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case Alplus.Billing.Access.check(Ash.Changeset.get_attribute(changeset, :org_id)) do
        {:ok, _access} -> changeset
        {:error, %{message: message}} -> Ash.Changeset.add_error(changeset, message: message)
      end
    end)
  end
end
