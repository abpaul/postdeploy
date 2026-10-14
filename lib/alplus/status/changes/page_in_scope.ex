defmodule Alplus.Status.Changes.PageInScope do
  @moduledoc false

  use Ash.Resource.Change

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def change(changeset, opts, _context) do
    page_id = Ash.Changeset.get_attribute(changeset, opts[:page_id_attribute])
    org_id = Ash.Changeset.get_attribute(changeset, :org_id)
    project_id = Ash.Changeset.get_attribute(changeset, :project_id)

    if is_nil(page_id) or is_nil(org_id) or is_nil(project_id) do
      changeset
    else
      case Ash.get(Alplus.Status.StatusPage, page_id, authorize?: false) do
        {:ok, %{org_id: ^org_id, project_id: ^project_id}} ->
          changeset

        _ ->
          Ash.Changeset.add_error(changeset,
            field: opts[:page_id_attribute],
            message: "does not exist"
          )
      end
    end
  end
end
