defmodule Alplus.Notifications.Validations.RelationshipsInOrg do
  @moduledoc """
  Keeps an alert rule's project and channel in the same organization as the
  rule. Foreign keys prove that both rows exist, but they do not prove that
  their organization ids agree.

  The action policy separately checks the live actor membership and manager
  role. This validation is the resource boundary that prevents a direct Ash
  caller from planting a cross-tenant relationship before policy evaluation
  reaches the row.
  """

  use Ash.Resource.Validation

  alias Alplus.Notifications.Channel
  alias Alplus.Projects.Project

  @impl true
  def validate(changeset, _opts, _context) do
    org_id = attribute_or_data(changeset, :org_id)
    project_id = attribute_or_data(changeset, :project_id)
    channel_id = attribute_or_data(changeset, :channel_id)

    if Enum.any?([org_id, project_id, channel_id], &is_nil/1) do
      :ok
    else
      with :ok <- project_in_org(project_id, org_id),
           :ok <- channel_in_org(channel_id, org_id) do
        :ok
      else
        {:error, :project} -> {:error, field: :project_id, message: "does not exist"}
        {:error, :channel} -> {:error, field: :channel_id, message: "does not exist"}
      end
    end
  end

  defp attribute_or_data(changeset, attribute) do
    Ash.Changeset.get_attribute(changeset, attribute) ||
      Ash.Changeset.get_data(changeset, attribute)
  end

  defp project_in_org(project_id, org_id) do
    case Ash.get(Project, project_id, authorize?: false) do
      {:ok, %Project{org_id: ^org_id}} -> :ok
      _ -> {:error, :project}
    end
  end

  defp channel_in_org(channel_id, org_id) do
    case Ash.get(Channel, channel_id, authorize?: false) do
      {:ok, %Channel{org_id: ^org_id}} -> :ok
      _ -> {:error, :channel}
    end
  end
end
