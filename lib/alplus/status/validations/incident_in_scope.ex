defmodule Alplus.Status.Validations.IncidentInScope do
  @moduledoc false

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    incident_id = Ash.Changeset.get_attribute(changeset, :incident_id)
    org_id = Ash.Changeset.get_attribute(changeset, :org_id)
    project_id = Ash.Changeset.get_attribute(changeset, :project_id)

    if is_nil(incident_id) do
      :ok
    else
      case Ash.get(Alplus.Monitoring.Incident, incident_id, authorize?: false) do
        {:ok, %{org_id: ^org_id, project_id: ^project_id}} -> :ok
        _ -> {:error, field: :incident_id, message: "does not exist in this project"}
      end
    end
  end
end
