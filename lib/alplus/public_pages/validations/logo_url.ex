defmodule Alplus.PublicPages.Validations.LogoUrl do
  @moduledoc false

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :logo_url) do
      nil -> :ok
      url when is_binary(url) -> validate_url(url)
      _ -> {:error, field: :logo_url, message: "must be a valid HTTP or HTTPS URL"}
    end
  end

  defp validate_url(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      :ok
    else
      {:error, field: :logo_url, message: "must be a valid HTTP or HTTPS URL"}
    end
  end
end
