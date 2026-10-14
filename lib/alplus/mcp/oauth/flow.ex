defmodule Alplus.Mcp.OAuth.Flow do
  @moduledoc false

  require Ash.Query

  alias Alplus.Mcp
  alias Alplus.Mcp.OAuth
  alias Alplus.Mcp.OAuth.ClientMetadata
  alias Alplus.Mcp.OAuthAccessToken
  alias Alplus.Mcp.OAuthAuthorizationCode
  alias Alplus.Mcp.OAuthClient
  alias Alplus.Mcp.OAuthDeviceCode
  alias Alplus.Mcp.OAuthGrant
  alias Alplus.Mcp.OAuthRefreshToken
  alias Alplus.Mcp.Principal
  alias Alplus.Mcp.Scope, as: McpScope
  alias Alplus.Orgs.Membership
  alias Alplus.Repo
  alias Alplus.Scope
  alias Alplus.Security.BearerToken
  alias ExMCP.Authorization.PKCE

  @max_state_bytes 512
  @code_challenge_regex ~r/\A[A-Za-z0-9_-]{43}\z/
  @serialized_keys ~w(
    response_type client_id redirect_uri scope state resource
    code_challenge code_challenge_method
  )
  @token_keys ~w(grant_type code code_verifier redirect_uri client_id resource)
  @refresh_keys ~w(grant_type refresh_token client_id resource)

  # A rotated refresh token presented again is normally a replay attack. Inside
  # this window it is far more often a lost token response or a duplicate
  # retry, which no client can prevent. A client that keeps a stale copy in a
  # second process can re-read its own store, so the window does not cover it.
  # The window is also the time an attacker has to use a stolen predecessor,
  # so keep it near the length of one retry.
  @refresh_reuse_grace_seconds 30

  @device_grant_type "urn:ietf:params:oauth:grant-type:device_code"
  @device_keys ~w(grant_type device_code client_id resource)
  @device_poll_interval_seconds 5

  # Consonants only, so a generated code cannot read as a word, and without
  # the characters a person confuses when copying from another screen.
  @user_code_alphabet ~c"BCDFGHJKLMNPQRSTVWXZ"
  @user_code_alphabet_size 20
  @user_code_length 8

  @type device_error ::
          :authorization_pending
          | :slow_down
          | :access_denied
          | :expired_token
          | :invalid_grant

  @doc "The `grant_type` value for the device authorization grant."
  @spec device_grant_type() :: String.t()
  def device_grant_type, do: @device_grant_type

  defmodule Request do
    @moduledoc false

    @enforce_keys [
      :client_id,
      :client_name,
      :redirect_uri,
      :state,
      :resource,
      :scope,
      :code_challenge,
      :code_challenge_method
    ]

    defstruct @enforce_keys

    @type t :: %__MODULE__{
            client_id: String.t(),
            client_name: String.t(),
            redirect_uri: String.t(),
            state: String.t(),
            resource: String.t(),
            scope: String.t(),
            code_challenge: String.t(),
            code_challenge_method: String.t()
          }
  end

  @spec validate_authorization_syntax(map()) ::
          :ok | {:error, :invalid_request | :invalid_scope}
  def validate_authorization_syntax(params) when is_map(params) do
    authorization_syntax(stringify_keys(params))
  end

  def validate_authorization_syntax(_params), do: {:error, :invalid_request}

  @spec validate_authorization_request(map()) ::
          {:ok, Request.t()} | {:error, :invalid_request | :invalid_scope}
  def validate_authorization_request(params) when is_map(params) do
    params = stringify_keys(params)

    with :ok <- authorization_syntax(params),
         {:ok, client_id} <- require_binary(params, "client_id"),
         {:ok, redirect_uri} <- require_binary(params, "redirect_uri"),
         {:ok, scope} <- require_scope(params),
         {:ok, state} <- require_state(params),
         {:ok, challenge} <- require_code_challenge(params),
         {:ok, client} <- ClientMetadata.fetch(client_id),
         :ok <- require_registered_redirect(client, redirect_uri) do
      {:ok,
       %Request{
         client_id: client_id,
         client_name: client.client_name,
         redirect_uri: redirect_uri,
         state: state,
         resource: params["resource"],
         scope: scope,
         code_challenge: challenge,
         code_challenge_method: "S256"
       }}
    else
      {:error, :invalid_scope} -> {:error, :invalid_scope}
      _ -> {:error, :invalid_request}
    end
  end

  def validate_authorization_request(_params), do: {:error, :invalid_request}

  defp authorization_syntax(params) do
    with :ok <- require_response_type(params),
         {:ok, client_id} <- require_binary(params, "client_id"),
         :ok <- require_client_id_form(client_id),
         {:ok, _redirect_uri} <- require_binary(params, "redirect_uri"),
         :ok <- require_resource(params),
         {:ok, _challenge} <- require_code_challenge(params),
         :ok <- require_s256(params),
         {:scope, {:ok, _scope}} <- {:scope, require_scope(params)},
         {:ok, _state} <- require_state(params) do
      :ok
    else
      {:scope, _reason} -> {:error, :invalid_scope}
      _ -> {:error, :invalid_request}
    end
  end

  defp require_client_id_form(client_id) do
    case ExMCP.Authorization.ClientIdMetadata.validate_url(client_id) do
      :ok -> :ok
      _ -> if String.trim(client_id) != "", do: :ok, else: :error
    end
  end

  @spec register_client(map()) :: {:ok, map()} | {:error, term()}
  def register_client(params) when is_map(params) do
    params = stringify_keys(params)
    name = params["client_name"]
    redirect_uris = List.wrap(params["redirect_uris"])

    cond do
      not is_binary(name) or String.trim(name) == "" ->
        {:error, :invalid_client_metadata}

      redirect_uris == [] or not Enum.all?(redirect_uris, &is_binary/1) ->
        {:error, :invalid_client_metadata}

      not Enum.all?(redirect_uris, &valid_redirect_uri?/1) ->
        {:error, :invalid_redirect_uri}

      true ->
        persist_registered_client(name, redirect_uris)
    end
  end

  def register_client(_params), do: {:error, :invalid_client_metadata}

  @spec error_redirect(Request.t(), String.t()) :: {:ok, String.t()} | {:error, :invalid_request}
  def error_redirect(%Request{redirect_uri: redirect_uri, state: state}, error)
      when is_binary(redirect_uri) and is_binary(state) and is_binary(error) do
    {:ok,
     callback_url(redirect_uri, %{
       "error" => error,
       "state" => state,
       "iss" => OAuth.issuer()
     })}
  end

  def error_redirect(_request, _error), do: {:error, :invalid_request}

  @spec registered_error_redirect(map(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_request}
  def registered_error_redirect(params, error) when is_map(params) and is_binary(error) do
    params = stringify_keys(params)

    with {:ok, client_id} <- require_binary(params, "client_id"),
         {:ok, redirect_uri} <- require_binary(params, "redirect_uri"),
         {:ok, client} <- ClientMetadata.fetch(client_id),
         :ok <- require_registered_redirect(client, redirect_uri) do
      query = %{"error" => error, "iss" => OAuth.issuer()}

      query =
        case require_state(params) do
          {:ok, state} -> Map.put(query, "state", state)
          _ -> query
        end

      {:ok, callback_url(redirect_uri, query)}
    else
      _ -> {:error, :invalid_request}
    end
  end

  def registered_error_redirect(_params, _error), do: {:error, :invalid_request}

  defp persist_registered_client(name, redirect_uris) do
    now = DateTime.utc_now()

    case Mcp.cache_oauth_client(
           %{
             issuer: OAuth.issuer(),
             client_id: Alplus.Id.generate(:mcp_oauth_client),
             client_name: name,
             redirect_uris: redirect_uris,
             fetched_at: now,
             expires_at: nil
           },
           authorize?: false
         ) do
      {:ok, client} ->
        {:ok,
         %{
           "client_id" => client.client_id,
           "client_name" => client.client_name,
           "redirect_uris" => client.redirect_uris,
           "token_endpoint_auth_method" => "none",
           "grant_types" => ["authorization_code", "refresh_token"],
           "response_types" => ["code"]
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec prune_expired() :: :ok
  def prune_expired do
    now = DateTime.utc_now()
    stale = DateTime.add(now, -7 * 24 * 60 * 60, :second)

    Repo.query!("DELETE FROM mcp_oauth_authorization_codes WHERE expires_at < $1", [now])
    Repo.query!("DELETE FROM mcp_oauth_access_tokens WHERE expires_at < $1", [now])
    Repo.query!("DELETE FROM mcp_oauth_device_codes WHERE expires_at < $1", [now])

    Repo.query!(
      """
      DELETE FROM mcp_oauth_refresh_tokens
      WHERE expires_at < $1
         OR (revoked_at IS NOT NULL AND revoked_at < $2)
         OR (rotated_at IS NOT NULL AND rotated_at < $2)
      """,
      [now, stale]
    )

    :ok
  end

  @spec serialize_authorization_request(Request.t()) :: %{String.t() => String.t()}
  def serialize_authorization_request(%Request{} = request) do
    %{
      "response_type" => "code",
      "client_id" => request.client_id,
      "redirect_uri" => request.redirect_uri,
      "scope" => request.scope,
      "state" => request.state,
      "resource" => request.resource,
      "code_challenge" => request.code_challenge,
      "code_challenge_method" => request.code_challenge_method
    }
  end

  @spec restore_authorization_request(map()) :: {:ok, Request.t()} | {:error, :invalid_request}
  def restore_authorization_request(params) when is_map(params) do
    params
    |> stringify_keys()
    |> Map.take(@serialized_keys)
    |> validate_authorization_request()
  end

  def restore_authorization_request(_params), do: {:error, :invalid_request}

  @spec authorize(Request.t(), Scope.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, :forbidden | :invalid_request}
  def authorize(
        %Request{} = request,
        %Scope{user_id: user_id, org_id: org_id, project_id: project_id} = scope,
        granted_scopes
      )
      when is_binary(user_id) and is_binary(org_id) and
             (is_nil(project_id) or is_binary(project_id)) and is_list(granted_scopes) do
    with {:ok, scopes} <- validate_granted_scopes(request.scope, granted_scopes),
         :ok <- resource_matches_scope(request.resource, scope),
         {:ok, client} <- ClientMetadata.fetch(request.client_id),
         :ok <- require_registered_redirect(client, request.redirect_uri) do
      issue_authorization(request, scope, client, scopes)
    else
      _ -> {:error, :invalid_request}
    end
  end

  def authorize(_request, _scope, _granted_scopes), do: {:error, :invalid_request}

  @spec deny(Request.t()) :: {:ok, String.t()} | {:error, :invalid_request}
  def deny(%Request{redirect_uri: redirect_uri, state: state})
      when is_binary(redirect_uri) and is_binary(state) do
    {:ok,
     callback_url(redirect_uri, %{
       "error" => "access_denied",
       "state" => state,
       "iss" => OAuth.issuer()
     })}
  end

  def deny(_request), do: {:error, :invalid_request}

  # --- RFC 8628 device authorization grant ------------------------------
  #
  # The authorization-code grant needs a browser on the same host as the
  # client, and a loopback port it can bind. An agent on a remote machine, in
  # a container, or in CI has neither. The device grant keeps browser consent
  # and keeps every token short-lived, but lets the person approve on any
  # device.

  @spec start_device_authorization(map()) ::
          {:ok, %{String.t() => term()}}
          | {:error, :invalid_request | :invalid_scope | :invalid_client}
  def start_device_authorization(params) when is_map(params) do
    params = stringify_keys(params)

    with {:ok, client_id} <- require_binary(params, "client_id"),
         :ok <- require_client_id_form(client_id),
         :ok <- require_resource(params),
         {:scope, {:ok, scope}} <- {:scope, require_scope(params)},
         {:client, {:ok, client}} <- {:client, ClientMetadata.fetch(client_id)},
         {:ok, record, device_code} <-
           create_device_code(client, params["resource"], requested_scopes(scope)) do
      {:ok, device_authorization_response(record, device_code)}
    else
      {:scope, _reason} -> {:error, :invalid_scope}
      {:client, _reason} -> {:error, :invalid_client}
      _ -> {:error, :invalid_request}
    end
  end

  def start_device_authorization(_params), do: {:error, :invalid_request}

  @doc """
  Loads a pending device authorization for the browser consent screen.
  """
  @spec device_code_for_user_code(String.t()) ::
          {:ok, OAuthDeviceCode.t()} | {:error, :not_found | :expired | :settled}
  def device_code_for_user_code(user_code) when is_binary(user_code) do
    with {:ok, normalized} <- normalize_user_code(user_code),
         {:ok, %OAuthDeviceCode{} = record} <-
           Mcp.get_oauth_device_code_by_user_code(normalized, authorize?: false) do
      cond do
        settled_device_code?(record) -> {:error, :settled}
        expired_device_code?(record) -> {:error, :expired}
        true -> {:ok, record}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def device_code_for_user_code(_user_code), do: {:error, :not_found}

  @spec approve_device_code(OAuthDeviceCode.t(), Scope.t(), [String.t()]) ::
          :ok | {:error, :forbidden | :invalid_request}
  def approve_device_code(
        %OAuthDeviceCode{} = record,
        %Scope{user_id: user_id, org_id: org_id, project_id: project_id} = scope,
        granted_scopes
      )
      when is_binary(user_id) and is_binary(org_id) and
             (is_nil(project_id) or is_binary(project_id)) and is_list(granted_scopes) do
    with false <- settled_device_code?(record),
         false <- expired_device_code?(record),
         {:ok, scopes} <- validate_granted_scopes(Enum.join(record.scopes, " "), granted_scopes),
         :ok <- resource_matches_scope(record.resource, scope),
         {:ok, client} <- get_client(record.oauth_client_id),
         {:ok, grant} <- create_device_grant(record, scope, client, scopes) do
      # The grant is created outside the approve guard, because it carries an
      # audit hook that must not nest in a transaction. A losing double submit
      # would otherwise leave a live grant nobody can account for.
      case Mcp.approve_oauth_device_code(record, %{grant_id: grant.id, scopes: scopes},
             authorize?: false
           ) do
        {:ok, _approved} ->
          :ok

        _ ->
          _ = Mcp.revoke_oauth_grant(grant, authorize?: false, actor: scope)
          {:error, :forbidden}
      end
    else
      _ -> {:error, :forbidden}
    end
  end

  def approve_device_code(_record, _scope, _granted_scopes), do: {:error, :invalid_request}

  @spec deny_device_code(OAuthDeviceCode.t()) :: :ok | {:error, :invalid_request}
  def deny_device_code(%OAuthDeviceCode{} = record) do
    case Mcp.deny_oauth_device_code(record, authorize?: false) do
      {:ok, _denied} -> :ok
      _ -> {:error, :invalid_request}
    end
  end

  def deny_device_code(_record), do: {:error, :invalid_request}

  @spec redeem_device_code(map()) ::
          {:ok, %{String.t() => term()}} | {:error, device_error()}
  def redeem_device_code(params) when is_map(params) do
    params = stringify_keys(params)

    with :ok <- require_device_params(params),
         {:ok, outcome} <- transact(fn -> redeem_device(params) end) do
      case outcome do
        {:issued, response, notifications} ->
          Ash.Notifier.notify(notifications)
          {:ok, response}

        {:pending, reason, notifications} ->
          Ash.Notifier.notify(notifications)
          {:error, reason}
      end
    else
      _ -> {:error, :invalid_grant}
    end
  end

  def redeem_device_code(_params), do: {:error, :invalid_grant}

  @spec device_poll_interval_seconds() :: pos_integer()
  def device_poll_interval_seconds, do: @device_poll_interval_seconds

  defp create_device_code(client, resource, scopes, attempts \\ 3) do
    attrs = %{
      oauth_client_id: client.id,
      user_code: generate_user_code(),
      resource: resource,
      scopes: scopes
    }

    case Mcp.issue_oauth_device_code(attrs, authorize?: false) do
      {:ok, record} ->
        case Ash.Resource.get_metadata(record, :device_code) do
          device_code when is_binary(device_code) and device_code != "" ->
            {:ok, record, device_code}

          _ ->
            {:error, :invalid_request}
        end

      # A user code is short, so two live requests can collide. Retry before
      # failing a request the person has not seen yet.
      {:error, _reason} when attempts > 1 ->
        create_device_code(client, resource, scopes, attempts - 1)

      {:error, _reason} ->
        {:error, :invalid_request}
    end
  end

  defp device_authorization_response(record, device_code) do
    verification_uri = OAuth.verification_uri()

    %{
      "device_code" => device_code,
      "user_code" => record.user_code,
      "verification_uri" => verification_uri,
      "verification_uri_complete" =>
        verification_uri <> "?user_code=" <> URI.encode_www_form(record.user_code),
      "expires_in" => DateTime.diff(record.expires_at, DateTime.utc_now(), :second),
      "interval" => @device_poll_interval_seconds
    }
  end

  defp create_device_grant(record, scope, client, scopes) do
    Mcp.authorize_oauth_grant(
      %{
        org_id: scope.org_id,
        project_id: scope.project_id,
        scope_mode: Atom.to_string(OAuth.resource_mode(record.resource)),
        user_id: scope.user_id,
        oauth_client_id: client.id,
        issuer: OAuth.issuer(),
        resource: record.resource,
        scopes: scopes
      },
      actor: scope
    )
  end

  defp redeem_device(params) do
    device_code = params["device_code"]
    prefix = BearerToken.short_prefix(device_code)
    hash = BearerToken.hash(device_code)

    with true <- is_binary(prefix),
         :ok <- lock_device_code(prefix),
         {:ok, record} <- get_device_code(prefix),
         true <- BearerToken.matches?(record.device_code_hash, hash),
         {:ok, client} <- get_client(record.oauth_client_id),
         :ok <- matching_device_bindings?(record, client, params) do
      advance_device_code(record)
    else
      _ -> {:ok, {:pending, :invalid_grant, []}}
    end
  end

  defp advance_device_code(record) do
    cond do
      not is_nil(record.consumed_at) ->
        {:ok, {:pending, :invalid_grant, []}}

      not is_nil(record.denied_at) ->
        {:ok, {:pending, :access_denied, []}}

      expired_device_code?(record) ->
        {:ok, {:pending, :expired_token, []}}

      # Throttling applies only while the request is still pending. A client
      # that polled early must not have to wait again once a person approved.
      is_nil(record.approved_at) and polled_too_soon?(record) ->
        touch_and_pend(record, :slow_down)

      is_nil(record.approved_at) ->
        touch_and_pend(record, :authorization_pending)

      true ->
        issue_device_tokens(record)
    end
  end

  defp issue_device_tokens(record) do
    # Issue from the scopes stored on this device code, not from the grant.
    # One client can hold several device codes, and a later consent rewrites
    # the shared grant, so the grant is not a record of what this person
    # approved for this machine.
    scopes = record.scopes

    with {:ok, grant} <- get_grant(record.grant_id),
         true <- grant_live?(grant, record.resource),
         true <- grant_membership_allows_scopes?(grant, scopes),
         true <- MapSet.subset?(MapSet.new(scopes), MapSet.new(grant.scopes)),
         {:ok, supersede_notifications} <- revoke_live_grant_tokens(grant.id),
         {:ok, _consumed, consume_notifications} <-
           Mcp.consume_oauth_device_code(record,
             authorize?: false,
             return_notifications?: true
           ),
         {:ok, access_token, access_notifications} <-
           issue_access_token(grant.id, record.resource, scopes),
         {:ok, refresh_token, refresh_notifications} <-
           issue_refresh_token(grant.id, record.resource, scopes),
         access_secret when is_binary(access_secret) and access_secret != "" <-
           Ash.Resource.get_metadata(access_token, :token),
         refresh_secret when is_binary(refresh_secret) and refresh_secret != "" <-
           Ash.Resource.get_metadata(refresh_token, :token) do
      {:ok,
       {:issued, token_response(access_token, access_secret, refresh_secret),
        supersede_notifications ++
          consume_notifications ++ access_notifications ++ refresh_notifications}}
    else
      # Roll back. Otherwise a partial failure commits the revocations and the
      # single-use stamp, and the client has nothing left to retry.
      _ -> {:error, :invalid_grant}
    end
  end

  defp touch_and_pend(record, reason) do
    notifications =
      case Mcp.touch_oauth_device_code_poll(record,
             authorize?: false,
             return_notifications?: true
           ) do
        {:ok, _touched, notifications} -> notifications
        _ -> []
      end

    {:ok, {:pending, reason, notifications}}
  end

  defp polled_too_soon?(%OAuthDeviceCode{last_polled_at: nil}), do: false

  defp polled_too_soon?(%OAuthDeviceCode{last_polled_at: last_polled_at}) do
    DateTime.diff(DateTime.utc_now(), last_polled_at, :second) < @device_poll_interval_seconds
  end

  defp settled_device_code?(%OAuthDeviceCode{} = record) do
    not is_nil(record.approved_at) or not is_nil(record.denied_at) or
      not is_nil(record.consumed_at)
  end

  defp expired_device_code?(%OAuthDeviceCode{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt
  end

  defp matching_device_bindings?(record, client, params) do
    # `client` was loaded by the record's own foreign key, so compare the
    # public identifier the caller presented, never the internal primary key.
    if client.client_id == params["client_id"] and record.resource == params["resource"] do
      :ok
    else
      :error
    end
  end

  defp lock_device_code(prefix) do
    case Repo.query!(
           """
           SELECT id
           FROM mcp_oauth_device_codes
           WHERE device_code_prefix = $1
           FOR UPDATE
           """,
           [prefix]
         ) do
      %{rows: [[_id]]} -> :ok
      _ -> {:error, :invalid_grant}
    end
  end

  defp get_device_code(prefix) do
    case Mcp.get_oauth_device_code_by_prefix(prefix, authorize?: false) do
      {:ok, %OAuthDeviceCode{} = record} -> {:ok, record}
      _ -> {:error, :invalid_grant}
    end
  end

  defp require_device_params(params) do
    if params["grant_type"] == @device_grant_type and
         Enum.all?(@device_keys, &present_param?(params[&1])) do
      :ok
    else
      {:error, :invalid_grant}
    end
  end

  defp generate_user_code do
    code = @user_code_length |> random_user_code_characters([]) |> List.to_string()
    String.slice(code, 0, 4) <> "-" <> String.slice(code, 4, 4)
  end

  defp random_user_code_characters(0, acc), do: acc

  defp random_user_code_characters(remaining, acc) do
    <<byte>> = :crypto.strong_rand_bytes(1)

    # 240 is the largest multiple of the alphabet size below 256. Rejecting
    # the tail keeps every character equally likely.
    if byte < 240 do
      character = Enum.at(@user_code_alphabet, rem(byte, @user_code_alphabet_size))
      random_user_code_characters(remaining - 1, [character | acc])
    else
      random_user_code_characters(remaining, acc)
    end
  end

  defp normalize_user_code(user_code) do
    cleaned = user_code |> String.upcase() |> String.replace(~r/[^A-Z]/, "")

    if String.length(cleaned) == @user_code_length and
         Enum.all?(String.to_charlist(cleaned), &(&1 in @user_code_alphabet)) do
      {:ok, String.slice(cleaned, 0, 4) <> "-" <> String.slice(cleaned, 4, 4)}
    else
      :error
    end
  end

  @spec exchange_code(map()) ::
          {:ok, %{String.t() => term()}} | {:error, :invalid_grant}
  def exchange_code(params) when is_map(params) do
    params = stringify_keys(params)

    with :ok <- require_token_params(params),
         {:ok, {response, notifications}} <- transact(fn -> redeem_code(params) end) do
      # Code consume and access+refresh insert must commit together, and the
      # code row is locked FOR UPDATE so concurrent exchangers cannot both
      # succeed. Nested Ash mutations return notifications so they can be
      # flushed after commit. Repo.transaction is the documented Ash escape hatch.
      Ash.Notifier.notify(notifications)
      {:ok, response}
    else
      _ -> {:error, :invalid_grant}
    end
  end

  def exchange_code(_params), do: {:error, :invalid_grant}

  @spec refresh_token(map()) ::
          {:ok, %{String.t() => term()}} | {:error, :invalid_grant}
  def refresh_token(params) when is_map(params) do
    params = stringify_keys(params)

    with :ok <- require_refresh_params(params),
         {:ok, outcome} <- transact(fn -> redeem_refresh(params) end) do
      # Refresh locks the presented token row, then either rotates and issues
      # a successor pair or returns the loaded grant as a replay outcome
      # without mutating it. Nested Ash notifications for rotation flush only
      # after that transaction commits. Family revocation runs after commit
      # so Alplus.Audit.Change is not nested inside the manual transaction.
      case outcome do
        {:issued, response, notifications} ->
          Ash.Notifier.notify(notifications)
          {:ok, response}

        {:replay, grant} ->
          revoke_replayed_grant(grant)
          {:error, :invalid_grant}
      end
    else
      _ -> {:error, :invalid_grant}
    end
  end

  def refresh_token(_params), do: {:error, :invalid_grant}

  @spec revoke_token(term(), term()) :: :ok
  def revoke_token(token, _token_type_hint) do
    _ = revoke_presented_token(token)
    :ok
  end

  @spec authenticate_access_token(String.t(), String.t()) ::
          {:ok, Principal.t()} | {:error, :unauthenticated | :revoked}
  def authenticate_access_token(token, resource)
      when is_binary(token) and byte_size(token) > 0 and is_binary(resource) do
    prefix = BearerToken.short_prefix(token)
    hash = BearerToken.hash(token)
    now = DateTime.utc_now()

    with true <- OAuth.resource_mode(resource) != :invalid,
         true <- is_binary(prefix),
         {:ok, access_token} <- get_access_token(prefix),
         true <- BearerToken.matches?(access_token.token_hash, hash),
         {:ok, grant} <- get_grant(access_token.grant_id) do
      cond do
        not is_nil(access_token.revoked_at) or not is_nil(grant.revoked_at) ->
          {:error, :revoked}

        not token_live?(access_token, resource, now) ->
          {:error, :unauthenticated}

        not grant_live?(grant, resource) ->
          {:error, :unauthenticated}

        not grant_membership_allows_scopes?(grant, access_token.scopes || grant.scopes) ->
          {:error, :unauthenticated}

        true ->
          touch_last_use(access_token, grant)
          {:ok, Principal.from_oauth(grant, access_token.scopes || grant.scopes)}
      end
    else
      _ -> {:error, :unauthenticated}
    end
  end

  def authenticate_access_token(_token, _resource), do: {:error, :unauthenticated}

  defp issue_authorization(request, scope, client, scopes) do
    attrs = %{
      org_id: scope.org_id,
      project_id: scope.project_id,
      scope_mode: Atom.to_string(OAuth.resource_mode(request.resource)),
      user_id: scope.user_id,
      oauth_client_id: client.id,
      issuer: OAuth.issuer(),
      resource: request.resource,
      scopes: scopes
    }

    with {:ok, grant} <- Mcp.authorize_oauth_grant(attrs, actor: scope),
         {:ok, authorization_code} <-
           Mcp.issue_oauth_authorization_code(
             %{
               grant_id: grant.id,
               oauth_client_id: client.id,
               redirect_uri: request.redirect_uri,
               resource: request.resource,
               scopes: scopes,
               code_challenge: request.code_challenge
             },
             authorize?: false
           ),
         code when is_binary(code) and code != "" <-
           Ash.Resource.get_metadata(authorization_code, :code) do
      {:ok,
       callback_url(request.redirect_uri, %{
         "code" => code,
         "state" => request.state,
         "iss" => OAuth.issuer()
       })}
    else
      {:error, _reason} -> {:error, :forbidden}
      _ -> {:error, :forbidden}
    end
  end

  defp redeem_code(params) do
    code = params["code"]
    prefix = BearerToken.short_prefix(code)
    hash = BearerToken.hash(code)

    with true <- is_binary(prefix),
         :ok <- lock_authorization_code(prefix),
         {:ok, authorization_code} <- get_authorization_code(prefix),
         true <- BearerToken.matches?(authorization_code.code_hash, hash),
         :ok <- usable_code?(authorization_code),
         {:ok, client} <- get_client(authorization_code.oauth_client_id),
         :ok <- matching_code_bindings?(authorization_code, client, params),
         {:ok, grant} <- get_grant(authorization_code.grant_id),
         true <- grant_live?(grant, authorization_code.resource),
         true <- grant_membership_allows_scopes?(grant, authorization_code.scopes),
         :ok <- verify_pkce(params["code_verifier"], authorization_code.code_challenge),
         {:ok, supersede_notifications} <- revoke_live_grant_tokens(grant.id),
         {:ok, _consumed, consume_notifications} <-
           Mcp.consume_oauth_authorization_code(authorization_code,
             authorize?: false,
             return_notifications?: true
           ),
         {:ok, access_token, access_notifications} <-
           issue_access_token(grant.id, authorization_code.resource, authorization_code.scopes),
         {:ok, refresh_token, refresh_notifications} <-
           issue_refresh_token(grant.id, authorization_code.resource, authorization_code.scopes),
         access_secret when is_binary(access_secret) and access_secret != "" <-
           Ash.Resource.get_metadata(access_token, :token),
         refresh_secret when is_binary(refresh_secret) and refresh_secret != "" <-
           Ash.Resource.get_metadata(refresh_token, :token) do
      {:ok,
       {token_response(access_token, access_secret, refresh_secret),
        supersede_notifications ++
          consume_notifications ++ access_notifications ++ refresh_notifications}}
    else
      _ -> {:error, :invalid_grant}
    end
  end

  defp redeem_refresh(params) do
    presented = params["refresh_token"]
    prefix = BearerToken.short_prefix(presented)
    hash = BearerToken.hash(presented)

    with true <- is_binary(prefix),
         :ok <- lock_refresh_token(prefix),
         {:ok, refresh_token} <- get_refresh_token(prefix),
         true <- BearerToken.matches?(refresh_token.token_hash, hash),
         {:ok, grant} <- get_refresh_grant(refresh_token.grant_id) do
      # Explicitly revoked refresh tokens (including a family superseded at
      # re-consent) are invalid_grant only. Replay detection applies to
      # rotated-but-not-revoked tokens so presenting an old superseded
      # token cannot revoke the new family.
      cond do
        not is_nil(refresh_token.revoked_at) ->
          {:error, :invalid_grant}

        is_nil(refresh_token.rotated_at) ->
          rotate_live_refresh(refresh_token, grant, params)

        true ->
          redeem_rotated_refresh(refresh_token, grant, params)
      end
    else
      _ -> {:error, :invalid_grant}
    end
  end

  defp rotate_live_refresh(refresh_token, grant, params) do
    with :ok <- usable_refresh?(refresh_token),
         {:ok, client} <- get_client(grant.oauth_client_id),
         :ok <- matching_refresh_bindings?(refresh_token, grant, client, params),
         true <- grant_membership_allows_scopes?(grant, refresh_token.scopes),
         {:ok, _rotated, rotate_notifications} <-
           Mcp.rotate_oauth_refresh_token(refresh_token,
             authorize?: false,
             return_notifications?: true
           ),
         {:ok, access_token, access_notifications} <-
           issue_access_token(grant.id, refresh_token.resource, refresh_token.scopes),
         {:ok, next_refresh, refresh_notifications} <-
           issue_refresh_token(
             grant.id,
             refresh_token.resource,
             refresh_token.scopes,
             refresh_token.id
           ),
         access_secret when is_binary(access_secret) and access_secret != "" <-
           Ash.Resource.get_metadata(access_token, :token),
         refresh_secret when is_binary(refresh_secret) and refresh_secret != "" <-
           Ash.Resource.get_metadata(next_refresh, :token) do
      {:ok,
       {:issued, token_response(access_token, access_secret, refresh_secret),
        rotate_notifications ++ access_notifications ++ refresh_notifications}}
    else
      _ -> {:error, :invalid_grant}
    end
  end

  # Rotate the unused successor instead of revoking the family, so one dropped
  # token response cannot end a connection. Outside the grace window, or once
  # the client has rotated past the successor, the presentation is a genuine
  # fork and replay handling revokes the grant.
  defp redeem_rotated_refresh(refresh_token, grant, params) do
    with true <- within_reuse_grace?(refresh_token),
         {:ok, successor} <- unused_successor(refresh_token) do
      rotate_live_refresh(successor, grant, params)
    else
      _ -> {:ok, {:replay, grant}}
    end
  end

  defp within_reuse_grace?(%OAuthRefreshToken{rotated_at: rotated_at}) do
    DateTime.diff(DateTime.utc_now(), rotated_at, :second) <= @refresh_reuse_grace_seconds
  end

  # Lock the successor row before reading it, so two concurrent retries inside
  # the grace window serialise instead of racing on a pre-lock snapshot.
  defp unused_successor(%OAuthRefreshToken{id: id}) do
    with :ok <- lock_successor_refresh_token(id) do
      OAuthRefreshToken
      |> Ash.Query.for_read(:read, %{}, authorize?: false)
      |> Ash.Query.filter(rotated_from_id == ^id and is_nil(rotated_at) and is_nil(revoked_at))
      |> Ash.read_one(authorize?: false)
      |> case do
        {:ok, %OAuthRefreshToken{} = successor} -> {:ok, successor}
        _ -> {:error, :invalid_grant}
      end
    end
  end

  defp lock_successor_refresh_token(rotated_from_id) do
    case Repo.query!(
           """
           SELECT id
           FROM mcp_oauth_refresh_tokens
           WHERE rotated_from_id = $1
           FOR UPDATE
           """,
           [rotated_from_id]
         ) do
      %{rows: [[_id]]} -> :ok
      _ -> {:error, :invalid_grant}
    end
  end

  defp revoke_replayed_grant(%OAuthGrant{revoked_at: revoked_at})
       when not is_nil(revoked_at),
       do: :ok

  defp revoke_replayed_grant(%OAuthGrant{} = grant) do
    actor = Principal.from_oauth(grant, grant.scopes)

    _ =
      Mcp.revoke_oauth_grant(grant,
        authorize?: false,
        actor: actor
      )

    :ok
  end

  defp revoke_presented_token(token) when is_binary(token) and byte_size(token) > 0 do
    prefix = BearerToken.short_prefix(token)

    if is_binary(prefix) do
      hash = BearerToken.hash(token)

      # A valid refresh token revokes the loaded grant outside a manual
      # transaction so Alplus.Audit.Change is not nested. Access-token
      # revocation stays token-specific.
      case matching_refresh_token(prefix, hash) do
        {:ok, refresh_token} ->
          revoke_presented_refresh_grant(refresh_token)

        :error ->
          case transact(fn -> {:ok, revoke_matching_access([], prefix, hash)} end) do
            {:ok, notifications} -> Ash.Notifier.notify(notifications)
            _ -> :ok
          end
      end
    end

    :ok
  end

  defp revoke_presented_token(_token), do: :ok

  defp matching_refresh_token(prefix, hash) do
    with {:ok, refresh_token} <- get_refresh_token(prefix),
         true <- BearerToken.matches?(refresh_token.token_hash, hash) do
      {:ok, refresh_token}
    else
      _ -> :error
    end
  end

  defp revoke_presented_refresh_grant(%OAuthRefreshToken{revoked_at: revoked_at})
       when not is_nil(revoked_at),
       do: :ok

  defp revoke_presented_refresh_grant(%OAuthRefreshToken{} = refresh_token) do
    case get_refresh_grant(refresh_token.grant_id) do
      {:ok, grant} -> revoke_replayed_grant(grant)
      _ -> :ok
    end
  end

  defp revoke_live_grant_tokens(grant_id) do
    with {:ok, access_notifications} <- revoke_live_access_tokens(grant_id),
         {:ok, refresh_notifications} <- revoke_live_refresh_tokens(grant_id) do
      {:ok, access_notifications ++ refresh_notifications}
    end
  end

  defp revoke_live_access_tokens(grant_id) do
    revoke_live_tokens(OAuthAccessToken, grant_id, fn token ->
      Mcp.revoke_oauth_access_token(token,
        authorize?: false,
        return_notifications?: true
      )
    end)
  end

  defp revoke_live_refresh_tokens(grant_id) do
    revoke_live_tokens(OAuthRefreshToken, grant_id, fn token ->
      Mcp.revoke_oauth_refresh_token(token,
        authorize?: false,
        return_notifications?: true
      )
    end)
  end

  defp revoke_live_tokens(resource, grant_id, revoke) do
    query =
      resource
      |> Ash.Query.for_read(:read, %{}, authorize?: false)
      |> Ash.Query.filter(grant_id == ^grant_id and is_nil(revoked_at))

    case Ash.read(query, authorize?: false) do
      {:ok, tokens} ->
        Enum.reduce_while(tokens, {:ok, []}, fn token, {:ok, notifications} ->
          case revoke.(token) do
            {:ok, _revoked, extra} when is_list(extra) ->
              {:cont, {:ok, notifications ++ extra}}

            {:ok, _revoked} ->
              {:cont, {:ok, notifications}}

            _ ->
              {:halt, {:error, :invalid_grant}}
          end
        end)

      _ ->
        {:error, :invalid_grant}
    end
  end

  defp revoke_matching_access(notifications, prefix, hash) do
    with {:ok, access_token} <- get_access_token(prefix),
         true <- BearerToken.matches?(access_token.token_hash, hash),
         true <- is_nil(access_token.revoked_at),
         {:ok, _revoked, extra} <-
           Mcp.revoke_oauth_access_token(access_token,
             authorize?: false,
             return_notifications?: true
           ) do
      notifications ++ extra
    else
      _ -> notifications
    end
  end

  defp issue_access_token(grant_id, resource, scopes) do
    Mcp.issue_oauth_access_token(
      %{grant_id: grant_id, resource: resource, scopes: scopes},
      authorize?: false,
      return_notifications?: true
    )
  end

  defp issue_refresh_token(grant_id, resource, scopes, rotated_from_id \\ nil) do
    attrs = %{grant_id: grant_id, resource: resource, scopes: scopes}

    attrs =
      if is_binary(rotated_from_id) do
        Map.put(attrs, :rotated_from_id, rotated_from_id)
      else
        attrs
      end

    Mcp.issue_oauth_refresh_token(attrs, authorize?: false, return_notifications?: true)
  end

  defp lock_authorization_code(prefix) do
    case Repo.query!(
           """
           SELECT id
           FROM mcp_oauth_authorization_codes
           WHERE code_prefix = $1
           FOR UPDATE
           """,
           [prefix]
         ) do
      %{rows: [[_id]]} -> :ok
      _ -> {:error, :invalid_grant}
    end
  end

  defp lock_refresh_token(prefix) do
    case Repo.query!(
           """
           SELECT id
           FROM mcp_oauth_refresh_tokens
           WHERE token_prefix = $1
           FOR UPDATE
           """,
           [prefix]
         ) do
      %{rows: [[_id]]} -> :ok
      _ -> {:error, :invalid_grant}
    end
  end

  defp usable_code?(%OAuthAuthorizationCode{consumed_at: consumed_at})
       when not is_nil(consumed_at),
       do: {:error, :invalid_grant}

  defp usable_code?(%OAuthAuthorizationCode{expires_at: expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
      :ok
    else
      {:error, :invalid_grant}
    end
  end

  defp usable_refresh?(%OAuthRefreshToken{revoked_at: revoked_at})
       when not is_nil(revoked_at),
       do: {:error, :invalid_grant}

  defp usable_refresh?(%OAuthRefreshToken{expires_at: expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
      :ok
    else
      {:error, :invalid_grant}
    end
  end

  defp matching_code_bindings?(authorization_code, client, params) do
    if authorization_code.redirect_uri == params["redirect_uri"] and
         authorization_code.resource == params["resource"] and
         client.client_id == params["client_id"] do
      :ok
    else
      {:error, :invalid_grant}
    end
  end

  defp matching_refresh_bindings?(refresh_token, grant, client, params) do
    resource = params["resource"]

    if refresh_token.resource == resource and grant.resource == resource and
         refresh_token.scopes == grant.scopes and
         client.client_id == params["client_id"] and grant_live?(grant, resource) and
         matching_refresh_scopes?(refresh_token.scopes, params) == :ok do
      :ok
    else
      {:error, :invalid_grant}
    end
  end

  defp matching_refresh_scopes?(granted, params) do
    case Map.fetch(params, "scope") do
      :error ->
        :ok

      {:ok, scope} when is_binary(scope) and byte_size(scope) > 0 ->
        requested = String.split(scope, " ", trim: true)

        if MapSet.new(requested) == MapSet.new(granted) do
          :ok
        else
          {:error, :invalid_grant}
        end

      _ ->
        {:error, :invalid_grant}
    end
  end

  defp verify_pkce(verifier, challenge) do
    with :ok <- PKCE.validate_verifier(verifier),
         true <- PKCE.validate_challenge(verifier, challenge) do
      :ok
    else
      _ -> {:error, :invalid_grant}
    end
  end

  defp token_response(access_token, access_secret, refresh_secret) do
    expires_in = DateTime.diff(access_token.expires_at, DateTime.utc_now(), :second)

    %{
      "access_token" => access_secret,
      "refresh_token" => refresh_secret,
      "token_type" => "Bearer",
      "expires_in" => max(expires_in, 1),
      "scope" => Enum.join(access_token.scopes, " ")
    }
  end

  defp token_live?(%OAuthAccessToken{} = access_token, resource, now) do
    is_list(access_token.scopes) and access_token.scopes != [] and
      access_token.resource == resource and is_nil(access_token.revoked_at) and
      DateTime.compare(access_token.expires_at, now) == :gt
  end

  defp grant_live?(%OAuthGrant{} = grant, resource) do
    is_nil(grant.revoked_at) and grant.resource == resource and grant.issuer == OAuth.issuer() and
      grant_scope_matches_resource?(grant, resource)
  end

  defp grant_membership_allows_scopes?(%OAuthGrant{org_id: org_id, user_id: user_id}, scopes)
       when is_binary(org_id) and is_binary(user_id) and is_list(scopes) do
    case current_membership_role(org_id, user_id) do
      role when role in ["owner", "admin"] ->
        true

      role when is_binary(role) ->
        not Enum.any?(scopes, &write_scope?/1)

      _ ->
        false
    end
  end

  defp grant_membership_allows_scopes?(_grant, _scopes), do: false

  defp current_membership_role(org_id, user_id) do
    Membership
    |> Ash.Query.for_read(:read, %{}, authorize?: false)
    |> Ash.Query.filter(org_id == ^org_id and user_id == ^user_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %Membership{role: role}} -> role
      _ -> nil
    end
  end

  defp write_scope?(scope), do: is_binary(scope) and String.ends_with?(scope, ":write")

  defp touch_last_use(access_token, grant) do
    _ = Mcp.touch_oauth_access_token(access_token, authorize?: false)
    _ = Mcp.touch_oauth_grant(grant, authorize?: false)
    :ok
  end

  defp get_authorization_code(prefix) do
    case Mcp.get_oauth_authorization_code_by_prefix(prefix, authorize?: false) do
      {:ok, %OAuthAuthorizationCode{} = code} -> {:ok, code}
      _ -> {:error, :invalid_grant}
    end
  end

  defp get_access_token(prefix) do
    case Mcp.get_oauth_access_token_by_prefix(prefix, authorize?: false) do
      {:ok, %OAuthAccessToken{} = token} -> {:ok, token}
      _ -> {:error, :unauthenticated}
    end
  end

  defp get_refresh_token(prefix) do
    case Mcp.get_oauth_refresh_token_by_prefix(prefix, authorize?: false) do
      {:ok, %OAuthRefreshToken{} = token} -> {:ok, token}
      _ -> {:error, :invalid_grant}
    end
  end

  defp get_grant(id) do
    case Mcp.get_oauth_grant(id, authorize?: false) do
      {:ok, %OAuthGrant{} = grant} -> {:ok, grant}
      _ -> {:error, :unauthenticated}
    end
  end

  defp get_refresh_grant(id) do
    case Mcp.get_oauth_grant(id, authorize?: false) do
      {:ok, %OAuthGrant{} = grant} -> {:ok, grant}
      _ -> {:error, :invalid_grant}
    end
  end

  defp get_client(id) do
    case Mcp.get_oauth_client(id, authorize?: false) do
      {:ok, %OAuthClient{} = client} -> {:ok, client}
      _ -> {:error, :invalid_grant}
    end
  end

  defp require_response_type(params) do
    if params["response_type"] == "code", do: :ok, else: :error
  end

  defp require_scope(params) do
    case require_binary(params, "scope") do
      {:ok, scope} -> canonicalize_requested_scope(scope)
      _ -> :error
    end
  end

  defp canonicalize_requested_scope(scope) do
    requested = String.split(scope, " ", trim: true)
    allowed = MapSet.new(McpScope.all())

    cond do
      requested == [] ->
        :error

      Enum.any?(requested, &(not MapSet.member?(allowed, &1))) ->
        :error

      true ->
        requested_set = MapSet.new(requested)
        {:ok, Enum.join(canonical_scopes(requested_set), " ")}
    end
  end

  defp validate_granted_scopes(requested_scope, granted_scopes) do
    requested = MapSet.new(requested_scopes(requested_scope))
    granted = MapSet.new(granted_scopes)

    if MapSet.size(granted) > 0 and MapSet.subset?(granted, requested) do
      {:ok, canonical_scopes(granted)}
    else
      :error
    end
  end

  defp requested_scopes(scope) when is_binary(scope) do
    requested_set = MapSet.new(String.split(scope, " ", trim: true))
    canonical_scopes(requested_set)
  end

  defp canonical_scopes(requested_set) do
    Enum.filter(McpScope.all(), &MapSet.member?(requested_set, &1))
  end

  defp require_resource(params) do
    if OAuth.resource_mode(params["resource"]) in [:project, :organization], do: :ok, else: :error
  end

  defp resource_matches_scope(resource, %Scope{org_id: org_id, project_id: project_id}) do
    case OAuth.resource_mode(resource) do
      :project when is_binary(project_id) ->
        :ok

      :organization when is_nil(project_id) ->
        case OAuth.organization_for_resource(resource) do
          {:ok, %{id: ^org_id}} -> :ok
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp grant_scope_matches_resource?(
         %OAuthGrant{scope_mode: "project", project_id: project_id},
         resource
       ),
       do: is_binary(project_id) and OAuth.resource_mode(resource) == :project

  defp grant_scope_matches_resource?(
         %OAuthGrant{scope_mode: "organization", project_id: nil, org_id: org_id},
         resource
       ) do
    case OAuth.organization_for_resource(resource) do
      {:ok, %{id: ^org_id}} -> true
      _ -> false
    end
  end

  defp grant_scope_matches_resource?(_grant, _resource), do: false

  defp require_s256(params) do
    if params["code_challenge_method"] == "S256", do: :ok, else: :error
  end

  defp require_state(params) do
    case require_binary(params, "state") do
      {:ok, state} when byte_size(state) in 1..@max_state_bytes -> {:ok, state}
      _ -> :error
    end
  end

  defp require_code_challenge(params) do
    case require_binary(params, "code_challenge") do
      {:ok, challenge} ->
        if Regex.match?(@code_challenge_regex, challenge), do: {:ok, challenge}, else: :error

      _ ->
        :error
    end
  end

  defp require_registered_redirect(%OAuthClient{redirect_uris: uris}, redirect_uri) do
    if valid_redirect_uri?(redirect_uri) and is_list(uris) and
         Enum.any?(uris, &registered_redirect_matches?(&1, redirect_uri)) do
      :ok
    else
      :error
    end
  end

  defp registered_redirect_matches?(redirect_uri, redirect_uri), do: true

  defp registered_redirect_matches?(registered_uri, requested_uri) do
    valid_redirect_uri?(registered_uri) and
      loopback_redirect_matches?(registered_uri, requested_uri)
  end

  # RFC 8252 requires exact redirect matching except for a loopback URI's port.
  defp loopback_redirect_matches?(registered_uri, requested_uri) do
    case {URI.parse(registered_uri), URI.parse(requested_uri)} do
      {%URI{scheme: "http", host: host} = registered,
       %URI{scheme: "http", host: host} = requested}
      when host in ["localhost", "127.0.0.1", "[::1]", "::1"] ->
        %{registered | authority: nil, port: nil} == %{requested | authority: nil, port: nil}

      _ ->
        false
    end
  end

  # Matches ExMCP.Authorization.ClientIdMetadata.valid_redirect_uri?/1:
  # HTTPS with a host, or HTTP loopback only. No userinfo or fragment.
  defp valid_redirect_uri?(uri) when is_binary(uri) and uri != "" do
    case URI.parse(uri) do
      %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}
      when is_binary(host) ->
        valid_redirect_host?(host)

      %URI{scheme: "http", host: host, userinfo: nil, fragment: nil}
      when host in ["localhost", "127.0.0.1", "[::1]", "::1"] ->
        true

      _invalid ->
        false
    end
  end

  defp valid_redirect_uri?(_uri), do: false

  defp valid_redirect_host?(host) do
    valid_ip_address?(host) or valid_dns_name?(host)
  end

  defp valid_ip_address?(host) do
    match?({:ok, _address}, :inet.parse_address(String.to_charlist(host)))
  end

  defp valid_dns_name?(host) when byte_size(host) in 1..253 do
    host
    |> String.split(".")
    |> Enum.all?(&Regex.match?(~r/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/, &1))
  end

  defp valid_dns_name?(_host), do: false

  defp require_token_params(params) do
    if params["grant_type"] == "authorization_code" and
         Enum.all?(@token_keys, &present_param?(params[&1])) do
      :ok
    else
      :error
    end
  end

  defp require_refresh_params(params) do
    if params["grant_type"] == "refresh_token" and
         Enum.all?(@refresh_keys, &present_param?(params[&1])) do
      :ok
    else
      :error
    end
  end

  defp present_param?(value), do: is_binary(value) and byte_size(value) > 0

  defp require_binary(params, key) do
    case params[key] do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> :error
    end
  end

  defp callback_url(redirect_uri, params) do
    uri = URI.parse(redirect_uri)

    query =
      uri.query
      |> decode_query()
      |> Map.merge(params)

    URI.to_string(%{uri | query: URI.encode_query(query)})
  end

  defp decode_query(nil), do: %{}
  defp decode_query(""), do: %{}
  defp decode_query(query), do: URI.decode_query(query)

  defp stringify_keys(params) do
    Map.new(params, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} when is_binary(key) -> {key, value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp transact(fun) do
    case Repo.transaction(fn ->
           case fun.() do
             {:ok, result} -> result
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end
end
