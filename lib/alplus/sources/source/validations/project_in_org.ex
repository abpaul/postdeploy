defmodule Alplus.Sources.Source.Validations.ProjectInOrg do
  @moduledoc """
  Rejects a create whose `project_id` does not belong to the submitted
  `org_id`.

  Without this, an owner or admin of org A could pair `org_id: <org A>`
  (which satisfies the create policy) with a foreign `project_id` from
  org B, and plant a Source, and later an ingest credential, on a project
  the actor does not own (AGENTS.md hard rule 2).

  The mismatch surfaces as a not-found style error on `project_id`, never
  a 403, so a cross-tenant id is indistinguishable from a missing one
  (ARCHITECTURE.md §4).
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    org_id = Ash.Changeset.get_attribute(changeset, :org_id)
    project_id = Ash.Changeset.get_attribute(changeset, :project_id)

    # Let the `allow_nil? false` attribute validations report a missing id.
    if is_nil(org_id) or is_nil(project_id) do
      :ok
    else
      case Ash.get(Alplus.Projects.Project, project_id, authorize?: false) do
        {:ok, %{org_id: ^org_id}} -> :ok
        _ -> {:error, field: :project_id, message: "does not exist"}
      end
    end
  end
end
