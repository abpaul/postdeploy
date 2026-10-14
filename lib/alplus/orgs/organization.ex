defmodule Alplus.Orgs.Organization do
  @moduledoc """
  A tenant root (ARCHITECTURE.md §3, §4). Every read/write is scoped to orgs
  where the actor holds a live membership row — checked at the query on
  every action, never assumed from an earlier lookup.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Orgs,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Alplus.Billing.Statuses

  postgres do
    table "organizations"
    repo Alplus.Repo

    # ARCHITECTURE.md §5 rule 4: every free-text column carries an
    # octet_length cap in the database, not only in the changeset.
    custom_statements do
      statement :name_length_check do
        up "ALTER TABLE organizations ADD CONSTRAINT organizations_name_length_check CHECK (octet_length(name) <= 200)"
        down "ALTER TABLE organizations DROP CONSTRAINT organizations_name_length_check"
      end

      statement :slug_length_check do
        up "ALTER TABLE organizations ADD CONSTRAINT organizations_slug_length_check CHECK (octet_length(slug) <= 63)"
        down "ALTER TABLE organizations DROP CONSTRAINT organizations_slug_length_check"
      end

      statement :public_token_length_check do
        up "ALTER TABLE organizations ADD CONSTRAINT organizations_public_token_length_check CHECK (public_token IS NULL OR octet_length(public_token) = 16)"
        down "ALTER TABLE organizations DROP CONSTRAINT organizations_public_token_length_check"
      end

      # The legacy plan column keeps its constraint while a rolled-back
      # release still reads it. The contract migration drops both.
      statement :plan_check do
        up "ALTER TABLE organizations ADD CONSTRAINT organizations_plan_check CHECK (plan_id IN ('trial', 'postdeploy'))"
        down "ALTER TABLE organizations DROP CONSTRAINT organizations_plan_check"
      end
    end
  end

  actions do
    defaults [:read]

    create :create do
      # Keep this legacy input during the expand phase. Console forms no
      # longer expose it; the later contract migration can remove it after
      # all callers use `public_token` URLs.
      accept [:name, :slug]

      # The durable account claim prevents an organization deletion from
      # resetting the trial clock. It runs in this create transaction.
      change Alplus.Orgs.Changes.StartTrial

      change Alplus.Orgs.Changes.CreateOwnerMembership

      change {Alplus.Audit.Change,
              action: "organization.create", subject_type: "organization", org_id_attribute: :id}
    end

    update :update do
      accept [:name]
      require_atomic? false

      change {Alplus.Audit.Change,
              action: "organization.update", subject_type: "organization", org_id_attribute: :id}
    end

    update :apply_billing_status do
      accept []
      require_atomic? false

      argument :status, :atom,
        allow_nil?: false,
        constraints: [one_of: Statuses.subscription()]

      # `legacy_plan_id` is written for the release that may still be serving
      # or may be rolled back to. The contract migration removes it.
      change fn changeset, _context ->
        status = Ash.Changeset.get_argument(changeset, :status)

        changeset
        |> Ash.Changeset.force_change_attribute(:billing_status, status)
        |> Ash.Changeset.force_change_attribute(
          :legacy_plan_id,
          if(status == :trialing, do: "trial", else: "postdeploy")
        )
      end
    end

    destroy :destroy do
      primary? true
      require_atomic? false

      change {Alplus.Audit.Change,
              action: "organization.destroy", subject_type: "organization", org_id_attribute: :id}
    end
  end

  policies do
    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type(:read) do
      authorize_if expr(exists(memberships, user_id == ^actor(:user_id)))
    end

    policy action_type(:update) do
      authorize_if expr(
                     exists(
                       memberships,
                       user_id == ^actor(:user_id) and role in ["owner", "admin"]
                     )
                   )
    end

    policy action_type(:destroy) do
      authorize_if expr(exists(memberships, user_id == ^actor(:user_id) and role == "owner"))
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "organization"
      public? true
      writable? false
      primary_key? true
      allow_nil? false
      default fn -> Alplus.Id.generate("organization") end
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 200
    end

    attribute :slug, :string do
      allow_nil? true
      public? true

      constraints max_length: 63,
                  match: ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/
    end

    attribute :public_token, :string do
      allow_nil? true
      public? true
      writable? false
      default &Alplus.PublicToken.generate/0

      constraints min_length: 16,
                  max_length: 16,
                  match: ~r/\A[0-9A-Za-z]{16}\z/
    end

    # Still the `plan_status` column: the release that may be rolled back to
    # reads it, so the rename waits for the contract migration.
    #
    # This value mirrors Stripe's subscription status. The webhook processor
    # writes it after a subscription upsert wins the event-order fence. New
    # organizations start `trialing`; the create action sets it alongside
    # `trial_ends_at`. There is one package, so no plan id decides access.
    attribute :billing_status, :atom,
      source: :plan_status,
      constraints: [one_of: Statuses.subscription()],
      allow_nil?: false,
      default: :active,
      public?: true,
      writable?: false

    # Written only so a rolled-back release keeps resolving access. Nothing
    # reads it here; `billing_status` decides trial or subscribed. The
    # contract migration drops the column and this attribute.
    attribute :legacy_plan_id, :string,
      source: :plan_id,
      allow_nil?: false,
      default: "trial",
      public?: false,
      writable?: false

    # Written once by the create action when the trial starts. Nothing ever
    # resets it; the migration backfills it for pre-trial rows.
    attribute :trial_ends_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      writable? false
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :memberships, Alplus.Orgs.Membership do
      destination_attribute :org_id
    end
  end

  identities do
    identity :unique_slug, [:slug]
    identity :unique_public_token, [:public_token]
  end
end
