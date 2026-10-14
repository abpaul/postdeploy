defmodule Mix.Tasks.Alplus.Changelog.DesignateVendor do
  @moduledoc """
  Designates an existing project's changelog as PostDeploy's vendor changelog.

  Pass the project's public token. The task never creates an organization or a
  project, and it is safe to run again for the same project.
  """

  use Mix.Task

  @shortdoc "Designates an existing project changelog as the vendor changelog"
  @usage "mix alplus.changelog.designate_vendor PROJECT_PUBLIC_TOKEN"

  @impl Mix.Task
  def run([public_token]) do
    Mix.Task.run("app.config")
    {:ok, _started} = Application.ensure_all_started(:alplus)

    case Alplus.Changelog.designate_vendor_by_public_token(public_token) do
      {:ok, changelog} ->
        Mix.shell().info("Vendor changelog designated for project #{changelog.project_id}")

      {:error, :project_not_found} ->
        Mix.raise("No project found with public token #{public_token}.")

      {:error, {:vendor_already_assigned, project}} ->
        Mix.raise(
          "A different changelog already owns the vendor flag: project \"#{project.name}\" " <>
            "(public token #{project.public_token})."
        )

      {:error, error} ->
        Mix.raise("Could not designate the vendor changelog: #{Exception.message(error)}")
    end
  end

  def run(_args) do
    Mix.raise("Usage: #{@usage}")
  end
end
