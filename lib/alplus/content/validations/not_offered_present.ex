defmodule Alplus.Content.Validations.NotOfferedPresent do
  @moduledoc """
  SITE-ARCHITECTURE.md §8 condition 4: a platform-heartbeat guide must state
  one thing PostDeploy does not do.

  Only fires when `docs_host` is set (see
  `Alplus.Content.Validations.SourcesMatchDocsHost`).
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :docs_host) do
      docs_host when docs_host in [nil, ""] ->
        :ok

      _docs_host ->
        if (Ash.Changeset.get_attribute(changeset, :not_offered) || []) == [] do
          {:error,
           field: :not_offered, message: "must state at least one thing PostDeploy does not do"}
        else
          :ok
        end
    end
  end
end
