defmodule Alplus.Seo.Competitor.Validations.ProfileInScope do
  @moduledoc false

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    org_id = Ash.Changeset.get_attribute(changeset, :org_id)
    project_id = Ash.Changeset.get_attribute(changeset, :project_id)
    profile_id = Ash.Changeset.get_attribute(changeset, :profile_id)

    if is_nil(org_id) or is_nil(project_id) or is_nil(profile_id) do
      :ok
    else
      case Ash.get(Alplus.Seo.Profile, profile_id, authorize?: false) do
        {:ok, %{org_id: ^org_id, project_id: ^project_id}} -> :ok
        _ -> {:error, field: :profile_id, message: "does not exist"}
      end
    end
  end
end
