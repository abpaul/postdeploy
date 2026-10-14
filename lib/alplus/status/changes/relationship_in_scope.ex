defmodule Alplus.Status.Changes.RelationshipInScope do
  @moduledoc false

  use Ash.Resource.Change

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def change(changeset, opts, _context) do
    org_id = Ash.Changeset.get_attribute(changeset, :org_id)
    project_id = Ash.Changeset.get_attribute(changeset, :project_id)
    parent_id = Ash.Changeset.get_attribute(changeset, opts[:attribute])

    if is_nil(org_id) or is_nil(project_id) or is_nil(parent_id) do
      changeset
    else
      case Ash.get(opts[:resource], parent_id, authorize?: false) do
        {:ok, %{org_id: ^org_id, project_id: ^project_id}} ->
          changeset

        _ ->
          Ash.Changeset.add_error(changeset, field: opts[:attribute], message: "does not exist")
      end
    end
  end
end
