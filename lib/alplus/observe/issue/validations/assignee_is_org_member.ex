defmodule Alplus.Observe.Issue.Validations.AssigneeIsOrgMember do
  @moduledoc """
  Rejects an `assignee_id` that is not a member of the issue's org.

  Tenant rule: the error message never confirms whether the user id exists
  at all — a foreign org's user id and a random id fail identically.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :assignee_id) do
      nil ->
        :ok

      assignee_id ->
        org_id = Ash.Changeset.get_attribute(changeset, :org_id)

        if member?(org_id, assignee_id) do
          :ok
        else
          {:error, field: :assignee_id, message: "is not a member of this organization"}
        end
    end
  end

  defp member?(org_id, assignee_id) do
    %{rows: rows} =
      Alplus.Repo.query!(
        "SELECT 1 FROM memberships WHERE org_id = $1 AND user_id = $2 LIMIT 1",
        [org_id, assignee_id]
      )

    rows != []
  end
end
