defmodule Alplus.Seo.Profile.Validations.MeasureSourceInScope do
  @moduledoc false

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    org_id = Ash.Changeset.get_attribute(changeset, :org_id)
    project_id = Ash.Changeset.get_attribute(changeset, :project_id)
    source_id = Ash.Changeset.get_attribute(changeset, :source_id)
    target = Ash.Changeset.get_attribute(changeset, :target)

    if is_nil(org_id) or is_nil(project_id) or is_nil(source_id) do
      :ok
    else
      case Ash.get(Alplus.Sources.Source, source_id, authorize?: false) do
        {:ok, %{org_id: ^org_id, project_id: ^project_id, type: :measure, hostname: hostname}}
        when is_binary(hostname) and is_binary(target) ->
          if provider_target(hostname) == provider_target(target),
            do: :ok,
            else: {:error, field: :target, message: "must match the Measure site hostname"}

        {:ok, %{org_id: ^org_id, project_id: ^project_id, type: :measure}} ->
          {:error, field: :target, message: "must match the Measure site hostname"}

        _ ->
          {:error, field: :source_id, message: "does not exist"}
      end
    end
  end

  defp provider_target("www." <> target), do: target
  defp provider_target(target), do: target
end
