defmodule Alplus.Status.PublicActor do
  @moduledoc false

  defstruct [:status_page_id, :status_slug, :public_page_id, :org_id, :project_id, :now]

  @doc "Builds the least-privilege actor used to discover one public slug."
  def for_slug(status_slug) when is_binary(status_slug),
    do: %__MODULE__{status_slug: status_slug}

  @doc "Builds the least-privilege actor for one published project page."
  def for_project(project_id) when is_binary(project_id),
    do: %__MODULE__{project_id: project_id}
end
