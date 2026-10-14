defmodule Alplus.Billing.StripeCustomer do
  @moduledoc "One Stripe customer per organization and Stripe environment."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Billing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "stripe_customers"
    repo Alplus.Repo

    custom_indexes do
      index [:org_id, :stripe_environment], unique: true
      index [:stripe_environment, :stripe_customer_id], unique: true
    end

    references do
      reference :organization, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [:org_id, :stripe_environment, :stripe_customer_id]
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
      constraints prefix: "bcus"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:stripe_customer) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :stripe_environment, :string, allow_nil?: false, public?: true
    attribute :stripe_customer_id, :string, allow_nil?: false, public?: true
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
