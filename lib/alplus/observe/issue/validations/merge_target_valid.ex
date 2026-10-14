defmodule Alplus.Observe.Issue.Validations.MergeTargetValid do
  @moduledoc """
  Guards `:merge`. The target must be a different issue in the SAME org,
  project, and Source (never a cross-tenant or cross-Source merge), must
  not itself be merged (no chains), and the issue being merged must not
  already be a canonical parent (children first unmerge, then re-merge).

  The error message never distinguishes "target does not exist" from
  "target is in another tenant" — both read as an invalid target.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :merged_into_issue_id) do
      nil -> :ok
      target_id -> validate_target(changeset, target_id)
    end
  end

  defp validate_target(changeset, target_id) do
    issue_id = Ash.Changeset.get_data(changeset, :id)
    org_id = Ash.Changeset.get_data(changeset, :org_id)
    project_id = Ash.Changeset.get_data(changeset, :project_id)
    source_id = Ash.Changeset.get_data(changeset, :source_id)

    cond do
      target_id == issue_id ->
        error("cannot merge an issue into itself")

      has_children?(issue_id) ->
        error("unmerge this issue's merged issues first")

      not valid_target?(org_id, project_id, source_id, target_id) ->
        error("is not a mergeable issue in this project")

      true ->
        :ok
    end
  end

  defp has_children?(issue_id) do
    %{rows: rows} =
      Alplus.Repo.query!(
        "SELECT 1 FROM issues WHERE merged_into_issue_id = $1 LIMIT 1",
        [issue_id]
      )

    rows != []
  end

  defp valid_target?(org_id, project_id, source_id, target_id) do
    %{rows: rows} =
      Alplus.Repo.query!(
        """
        SELECT 1 FROM issues
        WHERE id = $1 AND org_id = $2 AND project_id = $3
          AND source_id IS NOT DISTINCT FROM $4
          AND merged_into_issue_id IS NULL
        LIMIT 1
        """,
        [target_id, org_id, project_id, source_id]
      )

    rows != []
  end

  defp error(message), do: {:error, field: :merged_into_issue_id, message: message}
end
