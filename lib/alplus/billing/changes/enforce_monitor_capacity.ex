defmodule Alplus.Billing.Changes.EnforceMonitorCapacity do
  @moduledoc false

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      org_id = Ash.Changeset.get_attribute(changeset, :org_id)
      project_id = Ash.Changeset.get_attribute(changeset, :project_id)
      type = Ash.Changeset.get_attribute(changeset, :type)

      case Alplus.Billing.Access.allow_monitor_capacity(org_id, project_id, type) do
        {:ok, _entitlement} ->
          changeset

        {:error, %{message: message}} ->
          Ash.Changeset.add_error(changeset, field: :org_id, message: message)
      end
    end)
  end
end
