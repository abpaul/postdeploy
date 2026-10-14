defmodule Alplus.Billing.Changes.EnforceCapacity do
  @moduledoc false

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    metric = Keyword.fetch!(opts, :metric)

    # A blank AshPhoenix form builds this changeset before the org field is
    # present. This callback executes in Ash's create transaction, where the
    # entitlement query locks the organization until the insert commits.
    Ash.Changeset.before_action(changeset, fn changeset ->
      org_id = Ash.Changeset.get_attribute(changeset, :org_id)

      case Alplus.Billing.Access.allow_create(org_id, metric) do
        :ok ->
          changeset

        {:error, %{message: message}} ->
          Ash.Changeset.add_error(changeset, field: :org_id, message: message)
      end
    end)
  end
end
