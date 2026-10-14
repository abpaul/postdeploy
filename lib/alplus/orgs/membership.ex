defmodule Alplus.Orgs.Membership do
  @moduledoc """
  A user's role in one org (ARCHITECTURE.md §4). Exactly one `owner` per org
  and one membership per `(user, org)` are DB-enforced (see `custom_indexes`
  below), not just policy-enforced.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Orgs,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "memberships"
    repo Alplus.Repo

    custom_indexes do
      index [:org_id],
        unique: true,
        where: "role = 'owner'",
        name: "memberships_one_owner_per_org_index"
    end

    custom_statements do
      statement :role_check do
        up "ALTER TABLE memberships ADD CONSTRAINT memberships_role_check CHECK (role IN ('owner', 'admin', 'member'))"
        down "ALTER TABLE memberships DROP CONSTRAINT memberships_role_check"
      end
    end

    references do
      reference :organization, on_delete: :delete
      reference :user, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    # Used only to build `Alplus.Scope` (Alplus.Orgs.build_scope/2): looks up
    # the actor's own membership row for `organization_id`, so the scope's
    # `role` reflects the live DB row, not a client-supplied value.
    read :get_for_actor do
      get? true
      argument :organization_id, :string, allow_nil?: false
      filter expr(user_id == ^actor(:user_id) and org_id == ^arg(:organization_id))
    end

    # Repeats the tenant predicate at the query itself (ARCHITECTURE.md §4),
    # matching `Project`'s and `Invitation`'s `:list_for_org`. The read
    # policy alone only proves the actor belongs to *some* org shared with
    # each row; this filter pins the list to the one org the caller asked
    # for.
    read :list_for_org do
      argument :org_id, :string, allow_nil?: false
      filter expr(org_id == ^arg(:org_id))
    end

    create :create_from_invitation do
      description """
      Internal: creates a membership as part of accepting an invitation
      (Alplus.Orgs.Invitation.Changes.AcceptInvitation), inside that
      action's own transaction. Never expose to actors directly, and never
      call it outside that transaction — it has no
      `Alplus.Audit.Change` on purpose, since the outer `:accept` action
      already writes the "membership.invite_accept" row for this event;
      attaching one here would also register a nested `after_transaction`
      hook inside the still-open outer transaction, which Ash warns is
      unsafe.
      """

      accept [:org_id, :user_id]

      argument :role, :string do
        allow_nil? false
        default "member"
        constraints match: ~r/\A(admin|member)\z/
      end

      # The invitation being redeemed. Its own pending row still holds a seat
      # at this point -- `:accept` writes the status change after this
      # membership is created -- so the gate must not count it twice.
      argument :invitation_id, :string, allow_nil?: false

      change set_attribute(:role, arg(:role))
      change {Alplus.Billing.Changes.EnforceSeat, except_invitation_argument: :invitation_id}
    end

    create :create_owner do
      description "Internal: creates the owner membership for a new org. Never expose to actors directly."
      accept [:org_id, :user_id]
      change set_attribute(:role, "owner")
    end

    create :add_member do
      accept [:org_id, :user_id]

      argument :role, :string do
        allow_nil? false
        default "member"
        constraints match: ~r/\A(admin|member)\z/
      end

      change set_attribute(:role, arg(:role))
      change Alplus.Billing.Changes.EnforceSeat

      change {Alplus.Audit.Change, action: "membership.add", subject_type: "membership"}
    end

    update :change_role do
      accept []
      require_atomic? false

      argument :role, :string do
        allow_nil? false
        constraints match: ~r/\A(admin|member)\z/
      end

      change set_attribute(:role, arg(:role))
      validate {Alplus.Orgs.Validations.TargetRoleIsNot, role: "owner"}
      validate Alplus.Orgs.Validations.ActorIsNotTarget

      change {Alplus.Audit.Change, action: "membership.role_change", subject_type: "membership"}
    end

    update :promote_to_owner do
      accept []
      require_atomic? false
      change Alplus.Orgs.Changes.TransferOwnership
      validate Alplus.Orgs.Validations.ActorIsNotTarget

      change {Alplus.Audit.Change,
              action: "organization.ownership_transfer", subject_type: "membership"}
    end

    update :demote_from_owner do
      description "Internal: demotes the current owner as part of an atomic ownership transfer. Never expose to actors directly."
      accept []
      change set_attribute(:role, "admin")
    end

    destroy :destroy do
      primary? true
      require_atomic? false
      validate {Alplus.Orgs.Validations.TargetRoleIsNot, role: "owner"}

      change {Alplus.Audit.Change, action: "membership.remove", subject_type: "membership"}
    end
  end

  policies do
    # `create_owner`, `demote_from_owner`, and `create_from_invitation` carry
    # no policy on purpose. System code calls them with `authorize?: false`
    # inside a transaction. A bypass with `authorize_if always()` would open
    # them to any actor the moment someone adds a code interface for them.

    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:user_id))
      authorize_if expr(exists(organization.memberships, user_id == ^actor(:user_id)))
    end

    policy action(:add_member) do
      authorize_if expr(
                     exists(
                       organization.memberships,
                       user_id == ^actor(:user_id) and role in ["owner", "admin"]
                     )
                   )
    end

    policy action(:change_role) do
      authorize_if expr(
                     exists(
                       organization.memberships,
                       user_id == ^actor(:user_id) and role in ["owner", "admin"]
                     )
                   )
    end

    policy action(:promote_to_owner) do
      authorize_if expr(
                     exists(
                       organization.memberships,
                       user_id == ^actor(:user_id) and role == "owner"
                     )
                   )
    end

    policy action_type(:destroy) do
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
      constraints prefix: "membership"
      public? true
      writable? false
      primary_key? true
      allow_nil? false
      default fn -> Alplus.Id.generate("membership") end
    end

    attribute :role, :string do
      allow_nil? false
      public? true
      default "member"
      constraints match: ~r/\A(owner|admin|member)\z/
    end

    attribute :org_id, Alplus.Id do
      constraints prefix: "organization"
      public? true
      allow_nil? false
      writable? true
    end

    attribute :user_id, Alplus.Id do
      constraints prefix: "user"
      public? true
      allow_nil? false
      writable? true
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

    belongs_to :user, Alplus.Accounts.User do
      source_attribute :user_id
      define_attribute? false
      allow_nil? false
    end
  end

  identities do
    identity :unique_user_per_org, [:user_id, :org_id]
  end
end
