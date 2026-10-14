defmodule AlplusWeb.OAuthAuthorizationController do
  use AlplusWeb, :controller

  alias Alplus.Mcp.OAuth
  alias Alplus.Scope
  alias AlplusWeb.OAuthConsent

  @authorization_session_key :oauth_authorization_request

  def new(conn, params) do
    case conn.assigns[:current_user] do
      nil ->
        case OAuth.validate_authorization_syntax(params) do
          :ok ->
            conn
            |> put_session(:return_to, request_path(conn))
            |> redirect(to: ~p"/sign-in")

          {:error, reason} ->
            reject_authorization(conn, params, reason)
        end

      current_user ->
        case OAuth.validate_authorization_request(params) do
          {:ok, request} ->
            show_consent(conn, request, current_user)

          {:error, reason} ->
            reject_authorization(conn, params, reason)
        end
    end
  end

  def create(conn, params) do
    case peek_authorization_request(conn) do
      {:ok, serialized} ->
        case OAuth.restore_authorization_request(serialized) do
          {:ok, request} ->
            case params["decision"] do
              "deny" -> deny(conn, request)
              "allow" -> allow(conn, request, params)
              _ -> retry_consent(conn, request)
            end

          _ ->
            invalid_request(conn)
        end

      {:error, _reason} ->
        invalid_request(conn)
    end
  end

  defp allow(conn, request, params) do
    case OAuthConsent.granted_scopes(request.resource, request.scope, params) do
      {:ok, granted_scopes} ->
        with %Scope{} = scope <- selected_authorization_scope(conn, request, params),
             {:ok, callback} <- OAuth.authorize(request, scope, granted_scopes) do
          conn
          |> consume_authorization_request()
          |> redirect(external: callback)
        else
          _ -> retry_consent(conn, request)
        end

      :error ->
        retry_consent(
          conn,
          request,
          OAuthConsent.selected_scope_ids(params),
          OAuthConsent.empty_selection_message(request.resource)
        )
    end
  end

  defp retry_consent(conn, request) do
    retry_consent(conn, request, :all, OAuthConsent.invalid_selection_message(request.resource))
  end

  defp retry_consent(conn, request, selected_scope_ids, message) do
    case conn.assigns[:current_user] do
      nil ->
        invalid_request(conn)

      user when selected_scope_ids == :all ->
        conn
        |> put_flash(:error, message)
        |> show_consent(request, user)

      user ->
        show_consent(conn, request, user, selected_scope_ids, message)
    end
  end

  defp show_consent(
         conn,
         request,
         user,
         selected_scope_ids \\ :all,
         permission_error \\ nil
       ) do
    with {:ok, consent} <- OAuthConsent.context(request.resource, user),
         return_host when is_binary(return_host) <- uri_host(request.redirect_uri),
         {:ok, callback_origin} <- callback_origin(request.redirect_uri) do
      conn
      |> allow_consent_callback(callback_origin)
      |> put_session(@authorization_session_key, OAuth.serialize_authorization_request(request))
      |> render(:show,
        form_action: ~p"/oauth/authorize",
        return_note: "After approval, you will return to #{return_host}.",
        client_name: client_name(request),
        client_host: uri_host(request.client_id) || "Registered application",
        account_email: user.email,
        scope_groups: OAuthConsent.scope_groups(request.scope, selected_scope_ids),
        permission_error: permission_error,
        choices: consent.choices,
        organization: consent.organization,
        organization_mode?: consent.mode == :organization,
        read_write_available?: OAuthConsent.requested_write?(request.scope)
      )
    else
      _ -> fail_authorization(conn, request)
    end
  end

  defp deny(conn, request) do
    case OAuth.deny(request) do
      {:ok, callback} ->
        conn
        |> consume_authorization_request()
        |> redirect(external: callback)

      _ ->
        invalid_request(conn)
    end
  end

  defp peek_authorization_request(conn) do
    case get_session(conn, @authorization_session_key) do
      serialized when is_map(serialized) -> {:ok, serialized}
      _ -> {:error, :missing_request}
    end
  end

  defp consume_authorization_request(conn) do
    delete_session(conn, @authorization_session_key)
  end

  defp selected_authorization_scope(conn, request, params) do
    case conn.assigns[:current_user] do
      %{id: user_id} -> OAuthConsent.selected_scope(user_id, request.resource, params)
      _ -> nil
    end
  end

  defp client_name(request) do
    Map.get(request, :client_name) || Map.get(request, "client_name") || "An MCP client"
  end

  defp request_path(conn) do
    case conn.query_string do
      "" -> conn.request_path
      query -> conn.request_path <> "?" <> query
    end
  end

  defp fail_authorization(conn, request) do
    case OAuth.error_redirect(request, "access_denied") do
      {:ok, url} -> redirect(conn, external: url)
      _ -> invalid_request(conn)
    end
  end

  defp uri_host(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  defp callback_origin(redirect_uri) do
    case URI.parse(redirect_uri) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) and is_integer(port) ->
        if safe_callback_host?(host) do
          host = if String.contains?(host, ":"), do: "[#{host}]", else: host
          default_port = URI.default_port(scheme)
          port = if port == default_port, do: "", else: ":#{port}"
          {:ok, "#{scheme}://#{host}#{port}"}
        else
          {:error, :invalid_redirect_uri}
        end

      _ ->
        {:error, :invalid_redirect_uri}
    end
  end

  defp safe_callback_host?(host) do
    match?({:ok, _address}, :inet.parse_address(String.to_charlist(host))) or
      (byte_size(host) in 1..253 and
         host
         |> String.split(".")
         |> Enum.all?(&Regex.match?(~r/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/, &1)))
  end

  defp allow_consent_callback(conn, callback_origin) do
    case get_resp_header(conn, "content-security-policy") do
      [policy] ->
        put_resp_header(
          conn,
          "content-security-policy",
          String.replace(
            policy,
            "form-action 'self'",
            "form-action 'self' #{callback_origin}"
          )
        )

      _ ->
        conn
    end
  end

  defp reject_authorization(conn, params, reason) do
    error = if reason == :invalid_scope, do: "invalid_scope", else: "invalid_request"

    case OAuth.registered_error_redirect(params, error) do
      {:ok, url} -> redirect(conn, external: url)
      _ -> invalid_request(conn)
    end
  end

  defp invalid_request(conn), do: send_resp(conn, :bad_request, "Invalid authorization request")
end
