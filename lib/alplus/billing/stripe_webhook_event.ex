defmodule Alplus.Billing.StripeWebhookEvent do
  @moduledoc "Idempotency and claim ledger for Stripe webhook processing."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Billing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Alplus.Billing.Statuses

  postgres do
    table "stripe_webhook_events"
    repo Alplus.Repo

    custom_indexes do
      index [:stripe_environment, :stripe_event_id], unique: true
      index [:received_at]
      index [:claim_expires_at], where: "status IN ('pending', 'processing')"
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :stripe_environment,
        :stripe_event_id,
        :type,
        :api_version,
        :livemode,
        :payload_hash,
        :received_at
      ]
    end
  end

  policies do
    policy always() do
      forbid_if always()
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "whev"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:stripe_webhook_event) end
    end

    attribute :stripe_environment, :string, allow_nil?: false, public?: true
    attribute :stripe_event_id, :string, allow_nil?: false, public?: true
    attribute :type, :string, allow_nil?: false, public?: true
    attribute :api_version, :string, allow_nil?: true, public?: true
    attribute :livemode, :boolean, allow_nil?: false, public?: true
    attribute :payload_hash, :string, allow_nil?: false, public?: true

    attribute :status, :atom,
      constraints: [one_of: Statuses.webhook_event()],
      allow_nil?: false,
      default: :pending,
      public?: true

    attribute :attempt_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :claim_token, :string, allow_nil?: true, public?: true
    attribute :claim_fence, :integer, allow_nil?: false, default: 0, public?: true
    attribute :claim_expires_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :last_error, :string, allow_nil?: true, public?: true
    attribute :received_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :processed_at, :utc_datetime_usec, allow_nil?: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
