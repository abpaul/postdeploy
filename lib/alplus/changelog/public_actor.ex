defmodule Alplus.Changelog.PublicActor do
  @moduledoc false

  defstruct [:slug, :changelog_id, :entry_id, :org_id, :project_id, :now]

  @type t :: %__MODULE__{}

  @doc "Build the least-privilege actor used to discover one public slug."
  def for_slug(slug) when is_binary(slug), do: %__MODULE__{slug: slug}

  @doc "Build the least-privilege actor used to discover one public project."
  def for_project(project_id) when is_binary(project_id), do: %__MODULE__{project_id: project_id}
  @doc "Build the least-privilege actor used to discover the vendor changelog."
  def for_vendor, do: %__MODULE__{}
end
