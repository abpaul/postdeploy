defmodule Alplus.PublicPages.Validations.Slug do
  @moduledoc false

  use Ash.Resource.Validation

  @slug_pattern ~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/
  @reserved ~w(api admin www status dashboard share)

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :public_slug) do
      slug when is_binary(slug) ->
        cond do
          slug in @reserved ->
            {:error, field: :public_slug, message: "is reserved"}

          Regex.match?(@slug_pattern, slug) ->
            :ok

          true ->
            {:error,
             field: :public_slug, message: "must contain lowercase letters, numbers, and hyphens"}
        end

      _ ->
        {:error, field: :public_slug, message: "is required"}
    end
  end
end
