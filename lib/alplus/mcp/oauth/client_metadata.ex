defmodule Alplus.Mcp.OAuth.ClientMetadata do
  @moduledoc """
  Cached Client ID Metadata Document lookup for MCP OAuth.

  Validated CIMD is stored per `(issuer, client_id)`. Expired rows are
  refreshed through ExMCP with `:mcp_oauth_metadata_fetch_opts`.
  """

  alias Alplus.Mcp
  alias Alplus.Mcp.OAuth
  alias Alplus.Mcp.OAuthClient
  alias ExMCP.Authorization.ClientIdMetadata

  @cache_ttl_seconds 3600

  def fetch(client_id) when is_binary(client_id) do
    issuer = OAuth.issuer()

    case ClientIdMetadata.validate_url(client_id) do
      :ok ->
        case cached(issuer, client_id) do
          {:ok, %OAuthClient{} = client} -> {:ok, client}
          :miss -> refresh(issuer, client_id)
        end

      _ ->
        case cached(issuer, client_id) do
          {:ok, %OAuthClient{} = client} -> {:ok, client}
          :miss -> {:error, :unknown_client}
        end
    end
  end

  def fetch(_client_id), do: {:error, :invalid_client_id_url}

  defp cached(issuer, client_id) do
    case Mcp.get_oauth_client_by_issuer_and_client_id(issuer, client_id, authorize?: false) do
      {:ok, %OAuthClient{} = client} ->
        if fresh?(client), do: {:ok, client}, else: :miss

      _ ->
        :miss
    end
  end

  defp refresh(issuer, client_id) do
    now = DateTime.utc_now()

    with {:ok, metadata} <- ClientIdMetadata.fetch(client_id, fetch_opts()),
         {:ok, attrs} <- cache_attrs(issuer, client_id, metadata, now) do
      cache(attrs)
    end
  end

  defp cache(attrs) do
    case Mcp.cache_oauth_client(attrs, authorize?: false) do
      {:ok, %OAuthClient{} = client} -> {:ok, client}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cache_attrs(issuer, client_id, metadata, now) do
    with :ok <- ClientIdMetadata.validate(metadata, client_id) do
      {:ok,
       %{
         issuer: issuer,
         client_id: client_id,
         client_name: metadata["client_name"],
         redirect_uris: metadata["redirect_uris"],
         fetched_at: now,
         expires_at: DateTime.add(now, @cache_ttl_seconds, :second)
       }}
    end
  end

  defp fresh?(%OAuthClient{expires_at: nil}), do: true

  defp fresh?(%OAuthClient{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end

  defp fetch_opts do
    case Application.get_env(:alplus, :mcp_oauth_metadata_fetch_opts, []) do
      opts when is_list(opts) -> opts
      _ -> []
    end
  end
end
