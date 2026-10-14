defmodule Alplus.PublicPages.PublicActor do
  @moduledoc false

  defstruct [:slug, :kind, :public_page_id, :org_id, :project_id, :user_id, :now]

  @type t :: %__MODULE__{}

  @doc "Builds the least-privilege actor used to discover one public slug."
  def for_slug(slug, kind \\ nil) when is_binary(slug),
    do: %__MODULE__{slug: slug, kind: kind}

  @doc "Builds the least-privilege actor used to read one public project."
  def for_project(project_id) when is_binary(project_id),
    do: %__MODULE__{project_id: project_id}

  @doc "Builds the least-privilege actor for one resolved identity."
  def for_identity(identity) do
    %__MODULE__{
      slug: identity.public_slug,
      public_page_id: identity.id,
      org_id: identity.org_id,
      project_id: identity.project_id,
      now: DateTime.utc_now()
    }
  end
end
