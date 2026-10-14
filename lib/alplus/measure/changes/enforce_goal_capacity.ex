defmodule Alplus.Measure.Changes.EnforceGoalCapacity do
  @moduledoc """
  Enforces the plan's `:goals_per_project` cap at goal create time (issue
  #1). Mirrors `Alplus.Billing.Changes.EnforceCapacity`, but locks the
  *project* row instead of the organization row: the goal cap is scoped
  per project, not per org, so two concurrent creates for two different
  projects in the same org must not serialize against each other.

  Runs inside the create transaction so the lock holds until commit.
  """

  use Ash.Resource.Change

  alias Alplus.Billing.{Access, Package}

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      org_id = Ash.Changeset.get_attribute(changeset, :org_id)
      project_id = Ash.Changeset.get_attribute(changeset, :project_id)

      case allow_create(org_id, project_id) do
        :ok ->
          changeset

        {:error, message} ->
          Ash.Changeset.add_error(changeset, field: :name, message: message)
      end
    end)
  end

  defp allow_create(org_id, project_id) when is_binary(org_id) and is_binary(project_id) do
    with {:ok, _access} <- Access.check(org_id),
         {:ok, current} <- lock_project_and_count(org_id, project_id) do
      limit = Package.limit(:goals_per_project)

      if current < limit do
        :ok
      else
        {:error, "PostDeploy includes #{limit} goals per project. Remove one to add another."}
      end
    else
      _ -> {:error, "The project was not found."}
    end
  end

  defp allow_create(_org_id, _project_id),
    do: {:error, "An organization and project are required."}

  # Locking the project row (rather than counting unlocked) serializes
  # concurrent goal creates for the same project, so two simultaneous
  # requests cannot both observe the same "one slot left" count.
  defp lock_project_and_count(org_id, project_id) do
    case Alplus.Repo.query!(
           """
           WITH locked_project AS (
             SELECT id FROM projects WHERE id = $1 AND org_id = $2 FOR UPDATE
           )
           SELECT count(goals.id)
           FROM locked_project
           LEFT JOIN goals ON goals.project_id = locked_project.id
           GROUP BY locked_project.id
           """,
           [project_id, org_id]
         ).rows do
      [[count]] -> {:ok, count}
      [] -> :not_found
    end
  end
end
