defmodule Alplus.Mcp.Authorization do
  @moduledoc "Authenticates MCP OAuth access tokens and returns the narrow principal."

  alias Alplus.Mcp.OAuth
  alias Alplus.Mcp.Principal

  @spec authenticate(Plug.Conn.t()) ::
          {:ok, Principal.t()} | {:error, :unauthenticated | :revoked}
  def authenticate(%Plug.Conn{} = conn) do
    if query_token?(conn) do
      invalid()
    else
      case {bearer(conn), expected_resource(conn.request_path)} do
        {{:ok, token}, {:ok, resource}} -> authenticate_token(token, resource)
        _ -> invalid()
      end
    end
  end

  defp authenticate_token("mcoat_" <> _rest = token, resource),
    do: authenticate_oauth_token(token, resource)

  defp authenticate_token(_token, _resource), do: invalid()

  defp authenticate_oauth_token(token, resource) do
    case OAuth.authenticate_access_token(token, resource) do
      {:ok, %Principal{} = principal} ->
        accept_oauth_principal(principal)

      {:error, reason} when reason in [:unauthenticated, :revoked] ->
        invalid(reason)

      _ ->
        invalid()
    end
  end

  defp accept_oauth_principal(
         %Principal{
           grant_id: grant_id,
           org_id: org_id,
           project_id: project_id,
           user_id: user_id,
           resource: resource,
           scope_mode: scope_mode,
           source: :oauth
         } = principal
       )
       when is_binary(grant_id) and is_binary(org_id) and
              (is_nil(project_id) or is_binary(project_id)) and is_binary(user_id) and
              is_binary(resource) and scope_mode in [:project, :organization] do
    {:ok, principal}
  end

  defp accept_oauth_principal(_principal), do: invalid()

  defp expected_resource(path) when is_binary(path),
    do: path |> String.trim_trailing("/") |> expected_normalized_resource()

  defp expected_normalized_resource("/mcp"), do: {:ok, OAuth.resource_uri()}

  defp expected_normalized_resource("/mcp/org/" <> public_token) do
    resource = OAuth.resource_uri(public_token)

    if Regex.match?(~r/\A[0-9A-Za-z]{16}\z/, public_token) and
         OAuth.resource_mode(resource) == :organization,
       do: {:ok, resource},
       else: :error
  end

  defp expected_normalized_resource(_path), do: :error

  defp bearer(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) > 0 -> {:ok, String.trim(token)}
      _ -> :missing
    end
  end

  defp query_token?(conn) do
    conn.query_string != "" and
      Enum.any?(String.split(conn.query_string, "&"), fn part ->
        case String.split(part, "=", parts: 2) do
          [key, _value] -> key in ["token", "access_token", "api_key"]
          [key] -> key in ["token", "access_token", "api_key"]
          _ -> false
        end
      end)
  end

  defp invalid(reason \\ :unauthenticated) do
    # Revoked grants are deliberately indistinguishable from garbage, but
    # retain the same tarpit so revocation cannot become an oracle.
    if reason in [:unauthenticated, :revoked], do: Alplus.Observe.Tarpit.delay_invalid_key()
    {:error, reason}
  end
end
