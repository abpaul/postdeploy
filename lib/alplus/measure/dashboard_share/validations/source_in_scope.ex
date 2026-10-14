defmodule Alplus.Measure.DashboardShare.Validations.SourceInScope do
  @moduledoc false

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    org_id = Ash.Changeset.get_attribute(changeset, :org_id)
    project_id = Ash.Changeset.get_attribute(changeset, :project_id)
    source_id = Ash.Changeset.get_attribute(changeset, :source_id)

    if Enum.any?([org_id, project_id, source_id], &is_nil/1) do
      :ok
    else
      case Ash.get(Alplus.Sources.Source, source_id, authorize?: false) do
        {:ok, %{org_id: ^org_id, project_id: ^project_id, type: :measure, status: :active}} ->
          :ok

        _other ->
          {:error, field: :source_id, message: "does not exist"}
      end
    end
  end
end
