defmodule Alplus.Mcp do
  @moduledoc "Shared MCP boundary resources and cross-pillar dispatch."

  use Ash.Domain, otp_app: :alplus

  resources do
    resource Alplus.Mcp.IdempotencyRecord

    resource Alplus.Mcp.Confirmation do
      define :request_confirmation, action: :request
      define :get_confirmation, action: :read, get_by: [:id]
      define :list_confirmations_for_project, action: :list_for_project, args: [:project_id]
      define :transition_confirmation, action: :transition
    end

    resource Alplus.Mcp.OAuthClient do
      define :cache_oauth_client, action: :cache
      define :get_oauth_client, action: :read, get_by: [:id]

      define :get_oauth_client_by_issuer_and_client_id,
        action: :read,
        get_by: [:issuer, :client_id]
    end

    resource Alplus.Mcp.OAuthGrant do
      define :authorize_oauth_grant, action: :authorize
      define :get_oauth_grant, action: :read, get_by: [:id]
      define :list_oauth_grants, action: :list

      define :list_oauth_grant_labels_action,
        action: :list_labels,
        args: [:project_id, :grant_ids]

      define :revoke_oauth_grant, action: :revoke
      define :touch_oauth_grant, action: :touch
    end

    resource Alplus.Mcp.OAuthAuthorizationCode do
      define :issue_oauth_authorization_code, action: :issue
      define :get_oauth_authorization_code_by_prefix, action: :get_by_prefix, args: [:prefix]
      define :consume_oauth_authorization_code, action: :consume
    end

    resource Alplus.Mcp.OAuthDeviceCode do
      define :issue_oauth_device_code, action: :issue
      define :get_oauth_device_code_by_prefix, action: :get_by_prefix, args: [:prefix]
      define :get_oauth_device_code_by_user_code, action: :get_by_user_code, args: [:user_code]
      define :approve_oauth_device_code, action: :approve
      define :deny_oauth_device_code, action: :deny
      define :consume_oauth_device_code, action: :consume
      define :touch_oauth_device_code_poll, action: :touch_poll
    end

    resource Alplus.Mcp.OAuthAccessToken do
      define :issue_oauth_access_token, action: :issue
      define :get_oauth_access_token_by_prefix, action: :get_by_prefix, args: [:prefix]
      define :revoke_oauth_access_token, action: :revoke
      define :touch_oauth_access_token, action: :touch
    end

    resource Alplus.Mcp.OAuthRefreshToken do
      define :issue_oauth_refresh_token, action: :issue
      define :get_oauth_refresh_token, action: :read, get_by: [:id]
      define :get_oauth_refresh_token_by_prefix, action: :get_by_prefix, args: [:prefix]
      define :rotate_oauth_refresh_token, action: :rotate
      define :revoke_oauth_refresh_token, action: :revoke
    end
  end

  @doc "Returns only client labels for bounded, project-scoped activity rows."
  @spec list_oauth_grant_labels(String.t(), [String.t()], keyword()) ::
          {:ok, [%{id: String.t(), client_display_name: String.t() | nil}]} | {:error, term()}
  def list_oauth_grant_labels(project_id, grant_ids, opts \\ [])
      when is_binary(project_id) and is_list(grant_ids) do
    actor = Keyword.fetch!(opts, :actor)

    Alplus.Mcp.OAuthGrant
    |> Ash.Query.for_read(
      :list_labels,
      %{project_id: project_id, grant_ids: grant_ids},
      actor: actor
    )
    |> Ash.read(actor: actor)
    |> case do
      {:ok, grants} ->
        {:ok,
         Enum.map(grants, fn grant ->
           %{id: grant.id, client_display_name: grant.oauth_client.client_name}
         end)}

      error ->
        error
    end
  end
end
