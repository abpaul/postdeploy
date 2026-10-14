defmodule Alplus.Content.Validations.SourcesMatchDocsHost do
  @moduledoc """
  SITE-ARCHITECTURE.md §8 condition 3: a platform-heartbeat guide's failure
  mode claim must be citable from the platform's own documentation.

  Only fires when `docs_host` is set. Most `Guide` rows (`/privacy`,
  `/monitoring`, ...) are not platform pages and carry no `docs_host`, so
  they are unaffected.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :docs_host) do
      docs_host when docs_host in [nil, ""] ->
        :ok

      docs_host ->
        sources = Ash.Changeset.get_attribute(changeset, :sources) || []

        if Enum.any?(sources, &source_host_matches?(&1, docs_host)) do
          :ok
        else
          {:error,
           field: :sources,
           message:
             "must include at least one source whose URL host matches docs_host (#{docs_host})"}
        end
    end
  end

  defp source_host_matches?(%{"url" => url}, docs_host) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: ^docs_host} -> true
      _ -> false
    end
  end

  defp source_host_matches?(_source, _docs_host), do: false
end
