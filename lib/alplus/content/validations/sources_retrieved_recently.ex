defmodule Alplus.Content.Validations.SourcesRetrievedRecently do
  @moduledoc """
  A citation more than a year older than the human verification date is not
  evidence the failure mode still holds. Every `sources` entry's `retrieved`
  date must fall within 12 months of `last_verified_on`.

  Only fires when `docs_host` is set (see
  `Alplus.Content.Validations.SourcesMatchDocsHost`).
  """

  use Ash.Resource.Validation

  @max_days 366

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :docs_host) do
      docs_host when docs_host in [nil, ""] ->
        :ok

      _docs_host ->
        case Ash.Changeset.get_attribute(changeset, :last_verified_on) do
          nil ->
            {:error, field: :last_verified_on, message: "must be set when sources are cited"}

          %Date{} = last_verified_on ->
            sources = Ash.Changeset.get_attribute(changeset, :sources) || []

            if Enum.all?(sources, &retrieved_within_range?(&1, last_verified_on)) do
              :ok
            else
              {:error,
               field: :sources,
               message:
                 "every source's retrieved date must be within 12 months of last_verified_on"}
            end
        end
    end
  end

  defp retrieved_within_range?(%{"retrieved" => retrieved}, last_verified_on)
       when is_binary(retrieved) do
    case Date.from_iso8601(retrieved) do
      {:ok, date} -> abs(Date.diff(last_verified_on, date)) <= @max_days
      _ -> false
    end
  end

  defp retrieved_within_range?(_source, _last_verified_on), do: false
end
