defmodule Alplus.Billing.Subscription do
  @moduledoc "The current Stripe subscription mirror for an organization."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Billing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Alplus.Billing.Statuses

  postgres do
    table "subscriptions"
    repo Alplus.Repo

    custom_indexes do
      index [:org_id, :stripe_environment], unique: true
      index [:stripe_environment, :stripe_subscription_id], unique: true
    end

    references do
      reference :organization, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :org_id,
        :stripe_environment,
        :stripe_subscription_id,
        :status,
        :current_period_start,
        :current_period_end,
        :cancel_at_period_end,
        :event_created_at
      ]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action(:record) do
      forbid_if always()
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "sub"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:subscription) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :stripe_environment, :string, allow_nil?: false, public?: true
    attribute :stripe_subscription_id, :string, allow_nil?: false, public?: true

    # Written only so a rolled-back release keeps reading a populated mirror.
    # The package decides what is sold; the contract migration drops both
    # columns. The webhook upsert relies on their database defaults.
    attribute :legacy_plan_id, :string,
      source: :plan_id,
      allow_nil?: false,
      default: "postdeploy",
      public?: false,
      writable?: false

    attribute :legacy_billing_interval, :string,
      source: :billing_interval,
      allow_nil?: false,
      default: "monthly",
      public?: false,
      writable?: false

    attribute :status, :atom,
      constraints: [one_of: Statuses.subscription()],
      allow_nil?: false,
      public?: true

    attribute :current_period_start, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :current_period_end, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :cancel_at_period_end, :boolean, allow_nil?: false, default: false, public?: true
    attribute :event_created_at, :utc_datetime_usec, allow_nil?: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :organization, Alplus.Orgs.Organization,
      source_attribute: :org_id,
      define_attribute?: false,
      allow_nil?: false
  end
end
