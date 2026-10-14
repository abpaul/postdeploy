defmodule Alplus.Orgs.Invitation do
  @moduledoc """
  A pending invite to join an org (ARCHITECTURE.md §3, §4), valid for 7
  days. The token is a bearer capability (`Alplus.Security.BearerToken`):
  only its SHA-256 hash is stored, the raw token is returned once from
  `:invite`/`:resend`, and `:accept` is authorized by possessing it —
  the same "possession proves it" model as a password-reset token, not by
  a `memberships` row (the accepting actor has none yet).
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Orgs,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @expiry_seconds 7 * 24 * 60 * 60

  postgres do
    table "invitations"
    repo Alplus.Repo

    custom_indexes do
      index [:org_id, :email],
        unique: true,
        where: "status = 'pending'",
        name: "invitations_pending_email_index"
    end

    custom_statements do
      statement :email_normalized_check do
        up "ALTER TABLE invitations ADD CONSTRAINT invitations_email_normalized_check CHECK (email = lower(btrim(email)) AND octet_length(email) <= 320)"
        down "ALTER TABLE invitations DROP CONSTRAINT invitations_email_normalized_check"
      end

      statement :role_check do
        up "ALTER TABLE invitations ADD CONSTRAINT invitations_role_check CHECK (role IN ('admin', 'member'))"
        down "ALTER TABLE invitations DROP CONSTRAINT invitations_role_check"
      end

      statement :status_check do
        up "ALTER TABLE invitations ADD CONSTRAINT invitations_status_check CHECK (status IN ('pending', 'accepted', 'revoked', 'expired'))"
        down "ALTER TABLE invitations DROP CONSTRAINT invitations_status_check"
      end

      statement :token_hash_format_check do
        up "ALTER TABLE invitations ADD CONSTRAINT invitations_token_hash_format_check CHECK (token_hash ~ '^[0-9a-f]{64}$')"
        down "ALTER TABLE invitations DROP CONSTRAINT invitations_token_hash_format_check"
      end

      statement :expiry_after_creation_check do
        up "ALTER TABLE invitations ADD CONSTRAINT invitations_expiry_after_creation_check CHECK (expires_at > inserted_at)"
        down "ALTER TABLE invitations DROP CONSTRAINT invitations_expiry_after_creation_check"
      end
    end

    references do
      reference :organization, on_delete: :delete
      reference :invited_by, on_delete: :nilify
    end
  end

  actions do
    defaults [:read]

    # Repeats the tenant predicate at the query itself (ARCHITECTURE.md §4),
    # matching `Alplus.Projects.Project`'s `:list_for_org`.
    read :list_for_org do
      argument :org_id, :string, allow_nil?: false
      filter expr(org_id == ^arg(:org_id))
    end

    # System-only lookup used by `Alplus.Orgs.accept_invitation/2`, before
    # the accepting actor's membership exists — "possession is the
    # credential".
    read :get_by_token_hash do
      get? true
      argument :token_hash, :string, allow_nil?: false
      filter expr(token_hash == ^arg(:token_hash))
    end

    create :invite do
      accept [:org_id, :role]

      argument :email, :string, allow_nil?: false

      # Before anything mints a token or sends mail: no seat, no invitation.
      change Alplus.Billing.Changes.EnforceSeat
      change Alplus.Orgs.Invitation.Changes.NormalizeEmail
      change Alplus.Orgs.Invitation.Changes.GenerateToken
      change relate_actor(:invited_by, field: :user_id, allow_nil?: true)
      change Alplus.Orgs.Invitation.Changes.SendInvitationEmail

      metadata :token, :string, allow_nil?: false

      change {Alplus.Audit.Change, action: "membership.invite", subject_type: "invitation"}
    end

    update :resend do
      accept []
      require_atomic? false
      validate attribute_equals(:status, "pending")

      # Capacity must fail before a resend rotates the existing token.
      change Alplus.Billing.Changes.EnforceSeat
      change Alplus.Orgs.Invitation.Changes.GenerateToken
      change Alplus.Orgs.Invitation.Changes.SendInvitationEmail

      metadata :token, :string, allow_nil?: false

      change {Alplus.Audit.Change, action: "membership.invite_resend", subject_type: "invitation"}
    end

    update :revoke do
      accept []
      require_atomic? false
      validate attribute_equals(:status, "pending")
      change set_attribute(:status, "revoked")

      change {Alplus.Audit.Change, action: "membership.invite_revoke", subject_type: "invitation"}
    end

    update :accept do
      description """
      Authorized by possessing `token` (the raw secret), not by an
      existing membership — the accepting actor has none yet. Creates the
      membership for the actor as part of this action's transaction.
      """

      accept []
      require_atomic? false

      argument :token, :string, allow_nil?: false, sensitive?: true

      change Alplus.Orgs.Invitation.Changes.AcceptInvitation

      change {Alplus.Audit.Change, action: "membership.invite_accept", subject_type: "invitation"}
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(
                     exists(
                       organization.memberships,
                       user_id == ^actor(:user_id) and role in ["owner", "admin"]
                     )
                   )
    end

    policy action(:accept) do
      # Not membership-gated on purpose (see the action's @doc): the token
      # itself is the credential. `AcceptInvitation` rejects an unknown,
      # expired, or already-terminal token with a validation error.
      authorize_if actor_present()
    end

    policy action_type(:create) do
      authorize_if expr(
                     exists(
                       organization.memberships,
                       user_id == ^actor(:user_id) and role in ["owner", "admin"]
                     )
                   )
    end

    policy action([:resend, :revoke]) do
      authorize_if expr(
                     exists(
                       organization.memberships,
                       user_id == ^actor(:user_id) and role in ["owner", "admin"]
                     )
                   )
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "invitation"
      public? true
      writable? false
      primary_key? true
      allow_nil? false
      default fn -> Alplus.Id.generate("invitation") end
    end

    attribute :org_id, Alplus.Id do
      constraints prefix: "organization"
      public? true
      allow_nil? false
      writable? true
    end

    attribute :email, :string do
      allow_nil? false
      public? true
      constraints max_length: 320
    end

    attribute :role, :string do
      allow_nil? false
      public? true
      constraints match: ~r/\A(admin|member)\z/
    end

    attribute :token_hash, :string do
      allow_nil? false
      public? false
      writable? false
      sensitive? true
    end

    attribute :status, :string do
      allow_nil? false
      public? true
      default "pending"
      constraints match: ~r/\A(pending|accepted|revoked|expired)\z/
    end

    attribute :invited_by_id, Alplus.Id do
      constraints prefix: "user"
      public? true
      allow_nil? true
      writable? false
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      writable? false
    end

    attribute :accepted_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      writable? false
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :organization, Alplus.Orgs.Organization do
      source_attribute :org_id
      define_attribute? false
      allow_nil? false
    end

    belongs_to :invited_by, Alplus.Accounts.User do
      source_attribute :invited_by_id
      define_attribute? false
      allow_nil? true
    end
  end

  @doc "Seconds an invitation stays valid after it is created or resent."
  @spec expiry_seconds() :: pos_integer()
  def expiry_seconds, do: @expiry_seconds
end
