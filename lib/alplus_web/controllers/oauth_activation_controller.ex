defmodule AlplusWeb.OAuthActivationController do
  @moduledoc """
  Browser half of the RFC 8628 device flow. A person opens `/activate` on any
  device, types the user code their client printed, and approves the same
  permissions the authorization-code consent screen shows.
  """

  use AlplusWeb, :controller

  alias Alplus.Mcp.OAuth
  alias Alplus.Mcp.OAuth.DeviceRateLimiter
  alias Alplus.Scope
  alias AlplusWeb.OAuthConsent

  @device_session_key :oauth_device_code_id

  def new(conn, params) do
    case conn.assigns[:current_user] do
      nil ->
        conn
        |> put_session(:return_to, request_path(conn))
        |> redirect(to: ~p"/sign-in")

      _user ->
        render_code_entry(conn, params["user_code"] || "", nil)
    end
  end

  def create(conn, %{"decision" => decision} = params) do
    with %{} = user <- conn.assigns[:current_user],
         {:ok, device_code_id} <- peek_device_code(conn),
         {:ok, record} <- reload_pending(device_code_id) do
      case decision do
        "deny" -> deny(conn, record)
        "allow" -> allow(conn, record, user, params)
        _ -> show_consent(conn, record, user)
      end
    else
      _ ->
        render_code_entry(
          conn,
          "",
          "That code is no longer valid. Ask your client for a new one."
        )
    end
  end

  def create(conn, params) do
    case conn.assigns[:current_user] do
      nil ->
        conn
        |> put_session(:return_to, ~p"/activate")
        |> redirect(to: ~p"/sign-in")

      user ->
        # This answer says whether a user code exists, so it is a guessing
        # oracle. RFC 8628 section 5.2.
        case DeviceRateLimiter.check_user_code(conn.remote_ip) do
          :ok -> submit_user_code(conn, params, user)
          {:error, _retry_after} -> render_code_entry(conn, "", "Too many tries. Wait a minute.")
        end
    end
  end

  defp submit_user_code(conn, params, user) do
    case OAuth.device_code_for_user_code(params["user_code"] || "") do
      {:ok, record} ->
        show_consent(conn, record, user)

      {:error, :expired} ->
        render_code_entry(conn, "", "That code expired. Ask your client for a new one.")

      {:error, :settled} ->
        render_code_entry(conn, "", "That code was already used.")

      {:error, :not_found} ->
        render_code_entry(conn, params["user_code"] || "", "Check the code and try again.")
    end
  end

  defp allow(conn, record, user, params) do
    case OAuthConsent.granted_scopes(record.resource, Enum.join(record.scopes, " "), params) do
      {:ok, granted_scopes} ->
        with %Scope{} = scope <-
               OAuthConsent.selected_scope(user.id, record.resource, params),
             :ok <- OAuth.approve_device_code(record, scope, granted_scopes) do
          conn
          |> consume_device_code()
          |> render(:done, client_connected?: true)
        else
          _ ->
            show_consent(
              conn,
              record,
              user,
              :all,
              OAuthConsent.invalid_selection_message(record.resource)
            )
        end

      :error ->
        show_consent(
          conn,
          record,
          user,
          OAuthConsent.selected_scope_ids(params),
          OAuthConsent.empty_selection_message(record.resource)
        )
    end
  end

  defp deny(conn, record) do
    _ = OAuth.deny_device_code(record)

    conn
    |> consume_device_code()
    |> render(:done, client_connected?: false)
  end

  defp show_consent(conn, record, user, selected_scope_ids \\ :all, permission_error \\ nil) do
    requested_scope = Enum.join(record.scopes, " ")
    client = load_client(record)

    case OAuthConsent.context(record.resource, user) do
      {:ok, consent} ->
        conn
        |> put_session(@device_session_key, record.id)
        |> put_view(AlplusWeb.OAuthAuthorizationHTML)
        |> render(:show,
          form_action: ~p"/activate",
          return_note: "After approval, return to #{client_name(client)}.",
          client_name: client_name(client),
          client_host: client_provenance(client, record),
          # Anyone may register a client and choose its name, so a device code
          # can arrive from a stranger. Nothing else on this screen tells the
          # person that. RFC 8628 section 5.4.
          unsolicited_warning:
            "Continue only if you started this on a device you control. Anyone can name a client, so a code you did not ask for is not safe to approve.",
          account_email: user.email,
          scope_groups: OAuthConsent.scope_groups(requested_scope, selected_scope_ids),
          permission_error: permission_error,
          choices: consent.choices,
          organization: consent.organization,
          organization_mode?: consent.mode == :organization,
          read_write_available?: OAuthConsent.requested_write?(requested_scope)
        )

      _ ->
        render_code_entry(conn, "", "You cannot grant access for that request.")
    end
  end

  defp render_code_entry(conn, user_code, error) do
    conn
    |> consume_device_code()
    |> render(:new, user_code: user_code, error: error)
  end

  defp load_client(record) do
    case Ash.get(Alplus.Mcp.OAuthClient, record.oauth_client_id, authorize?: false) do
      {:ok, client} -> client
      _ -> nil
    end
  end

  defp client_name(%{client_name: name}) when is_binary(name) and name != "", do: name
  defp client_name(_client), do: "your client"

  # A CIMD client proves a host. A dynamically registered client proves
  # nothing, so show its age instead of letting a chosen name stand alone.
  defp client_provenance(%{client_id: "https://" <> _ = client_id}, record) do
    case URI.parse(client_id) do
      %URI{host: host} when is_binary(host) and host != "" ->
        "#{host}, device code #{record.user_code}"

      _ ->
        "Registered client, device code #{record.user_code}"
    end
  end

  defp client_provenance(%{inserted_at: inserted_at}, record) when not is_nil(inserted_at) do
    minutes = max(0, DateTime.diff(DateTime.utc_now(), inserted_at, :second)) |> div(60)

    "Unverified client, registered #{minutes} minutes ago, device code #{record.user_code}"
  end

  defp client_provenance(_client, record), do: "Device code #{record.user_code}"

  # The consent step must reload the row, because the request may have expired
  # or been settled in another tab while the person read the screen.
  defp reload_pending(device_code_id) do
    case Ash.get(Alplus.Mcp.OAuthDeviceCode, device_code_id, authorize?: false) do
      {:ok, record} -> OAuth.device_code_for_user_code(record.user_code)
      _ -> {:error, :not_found}
    end
  end

  defp peek_device_code(conn) do
    case get_session(conn, @device_session_key) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :missing_request}
    end
  end

  defp consume_device_code(conn), do: delete_session(conn, @device_session_key)

  defp request_path(conn) do
    case conn.query_string do
      "" -> conn.request_path
      query -> conn.request_path <> "?" <> query
    end
  end
end
