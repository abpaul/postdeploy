defmodule Alplus.Orgs do
  @moduledoc """
  Organizations and memberships (ARCHITECTURE.md §3, §4).

  Every function here takes `scope` (or `actor`) as its first argument and
  passes it straight through as the Ash actor — Ash policies do the tenant
  scoping at the query, on every call.
  """

  use Ash.Domain,
    otp_app: :alplus

  resources do
    resource Alplus.Orgs.Organization do
      define :create_organization, action: :create
      define :get_organization, action: :read, get_by: [:id]
      define :get_organization_by_public_token, action: :read, get_by: [:public_token]
      define :list_organizations, action: :read
      define :update_organization, action: :update

      define :apply_billing_status_state, action: :apply_billing_status, args: [:status]

      define :destroy_organization, action: :destroy
    end

    resource Alplus.Orgs.Membership do
      define :add_member, action: :add_member
      define :get_membership, action: :read, get_by: [:id]
      define :list_memberships, action: :read
      define :list_memberships_for_org, action: :list_for_org, args: [:org_id]
      define :change_member_role, action: :change_role
      define :promote_to_owner, action: :promote_to_owner
      define :remove_member, action: :destroy
    end

    resource Alplus.Orgs.Invitation do
      define :invite_member, action: :invite
      define :get_invitation, action: :read, get_by: [:id]
      define :list_invitations, action: :read
      define :list_invitations_for_org, action: :list_for_org, args: [:org_id]
      define :resend_invitation, action: :resend
      define :revoke_invitation, action: :revoke
    end
  end

  require Ash.Query

  @doc """
  Builds the caller's scope for `org_id`: looks up the actor's own
  membership row for that org and caches its live role on the scope.

  Returns `{:error, :not_found}` for a cross-tenant org id or a user with no
  membership in it — never a forbidden (ARCHITECTURE.md §4).
  """
  @spec build_scope(Alplus.Scope.t(), String.t()) ::
          {:ok, Alplus.Scope.t()} | {:error, :not_found}
  def build_scope(%Alplus.Scope{} = scope, org_id) when is_binary(org_id) do
    Alplus.Orgs.Membership
    |> Ash.Query.for_read(:get_for_actor, %{organization_id: org_id}, actor: scope)
    |> Ash.read_one()
    |> case do
      {:ok, %Alplus.Orgs.Membership{role: role}} ->
        {:ok, Alplus.Scope.put_org(scope, org_id, role)}

      {:ok, nil} ->
        {:error, :not_found}

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @doc """
  Accepts an invitation by its raw token: looks the invitation up by the
  token's hash (`authorize?: false` — possessing the raw token is the
  credential, matching a password-reset flow; the accepting actor has no
  membership to authorize against yet), then runs `Invitation`'s `:accept`
  action as `scope`'s user, which creates their membership in the same
  transaction.

  Returns `{:error, :not_found}` for an unknown token — never distinguishes
  that from an expired/revoked/already-accepted one at this layer; the
  action's validation errors carry that detail for a caller that read the
  invitation directly.
  """
  @spec accept_invitation(Alplus.Scope.t(), String.t()) ::
          {:ok, Alplus.Orgs.Invitation.t()} | {:error, :not_found | Ash.Error.t()}
  def accept_invitation(%Alplus.Scope{} = scope, raw_token) when is_binary(raw_token) do
    hash = Alplus.Security.BearerToken.hash(raw_token)

    Alplus.Orgs.Invitation
    |> Ash.Query.for_read(:get_by_token_hash, %{token_hash: hash}, authorize?: false)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %Alplus.Orgs.Invitation{} = invitation} ->
        Ash.update(invitation, %{token: raw_token}, action: :accept, actor: scope)

      {:ok, nil} ->
        {:error, :not_found}

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @doc """
  Looks an invitation up by its raw token for display on the public accept
  page (`AlplusWeb.InvitationAcceptLive`), before the visitor has signed in
  or matched the invited email — same `authorize?: false` "possession is
  the credential" lookup as `accept_invitation/2`'s first step, but read
  only, so a visitor can see who invited them and to what before deciding
  to sign in or register. Loads `:organization` for display.

  Returns `{:error, :not_found}` for an unknown token.
  """
  @spec get_invitation_by_token(String.t()) ::
          {:ok, Alplus.Orgs.Invitation.t()} | {:error, :not_found}
  def get_invitation_by_token(raw_token) when is_binary(raw_token) do
    hash = Alplus.Security.BearerToken.hash(raw_token)

    Alplus.Orgs.Invitation
    |> Ash.Query.for_read(:get_by_token_hash, %{token_hash: hash}, authorize?: false)
    |> Ash.Query.load(:organization)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %Alplus.Orgs.Invitation{} = invitation} -> {:ok, invitation}
      {:ok, nil} -> {:error, :not_found}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Lists one org's members, oldest first, with each member's `:user` loaded.

  The org predicate is repeated on top of the action's own filter, so a
  cross-tenant row can never reach the caller.
  """
  @spec list_org_members(Alplus.Scope.t(), String.t()) ::
          {:ok, [Alplus.Orgs.Membership.t()]} | {:error, term()}
  def list_org_members(scope, org_id) when is_binary(org_id) do
    Alplus.Orgs.Membership
    |> Ash.Query.for_read(:list_for_org, %{org_id: org_id}, actor: scope)
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.load(:user)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read(actor: scope)
  end

  @doc "Lists one org's invitations, newest first, in every status."
  @spec list_org_invitations(Alplus.Scope.t(), String.t()) ::
          {:ok, [Alplus.Orgs.Invitation.t()]} | {:error, term()}
  def list_org_invitations(scope, org_id) when is_binary(org_id) do
    Alplus.Orgs.Invitation
    |> Ash.Query.for_read(:list_for_org, %{org_id: org_id}, actor: scope)
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read(actor: scope)
  end

  @doc "Fetches one membership by id inside `org_id`, with `:user` loaded."
  @spec fetch_org_member(Alplus.Scope.t(), String.t(), String.t()) ::
          {:ok, Alplus.Orgs.Membership.t() | nil} | {:error, term()}
  def fetch_org_member(scope, org_id, id) when is_binary(org_id) and is_binary(id) do
    Alplus.Orgs.Membership
    |> Ash.Query.for_read(:read, %{}, actor: scope)
    |> Ash.Query.filter(org_id == ^org_id and id == ^id)
    |> Ash.Query.load(:user)
    |> Ash.read_one(actor: scope)
  end

  @doc "Fetches one invitation by id inside `org_id`."
  @spec fetch_org_invitation(Alplus.Scope.t(), String.t(), String.t()) ::
          {:ok, Alplus.Orgs.Invitation.t() | nil} | {:error, term()}
  def fetch_org_invitation(scope, org_id, id) when is_binary(org_id) and is_binary(id) do
    Alplus.Orgs.Invitation
    |> Ash.Query.for_read(:read, %{}, actor: scope)
    |> Ash.Query.filter(org_id == ^org_id and id == ^id)
    |> Ash.read_one(actor: scope)
  end

  @doc """
  Applies Billing's resolved Stripe subscription status to an Organization.

  The Ash update joins Billing's existing repository transaction. This keeps
  subscription ordering, the Organization transition, and webhook completion
  atomic while the Orgs domain retains ownership of Organization state.
  """
  @spec apply_billing_status(String.t(), String.t()) ::
          :ok | {:error, :organization_not_found | :invalid_billing_status}
  def apply_billing_status(org_id, status) when is_binary(org_id) and is_binary(status) do
    with :ok <- validate_billing_status(status),
         {:ok, organization} <- get_organization(org_id, authorize?: false) do
      case apply_billing_status_state(
             organization,
             String.to_existing_atom(status),
             authorize?: false,
             return_notifications?: true
           ) do
        {:ok, _organization, _notifications} -> :ok
        {:error, error} -> {:error, error}
      end
    else
      {:error, %Ash.Error.Invalid{}} -> {:error, :organization_not_found}
      {:error, _reason} = error -> error
    end
  end

  def apply_billing_status(_, _), do: {:error, :invalid_billing_status}

  defp validate_billing_status(status)
       when status in ~w(active past_due canceled incomplete incomplete_expired paused trialing unpaid),
       do: :ok

  defp validate_billing_status(_), do: {:error, :invalid_billing_status}
end
