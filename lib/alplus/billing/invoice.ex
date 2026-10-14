defmodule Alplus.Billing.Invoice do
  @moduledoc "An immutable Stripe invoice mirror, scoped to its organization."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Billing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Alplus.Billing.Statuses

  postgres do
    table "invoices"
    repo Alplus.Repo

    custom_indexes do
      index [:stripe_environment, :stripe_invoice_id], unique: true
      index [:org_id, :inserted_at]
    end

    references do
      reference :organization, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    read :list_for_org do
      argument :stripe_environment, :string, allow_nil?: false
      filter expr(org_id == ^actor(:org_id) and stripe_environment == ^arg(:stripe_environment))
      prepare build(sort: [inserted_at: :desc])
    end

    create :record do
      accept [
        :org_id,
        :stripe_environment,
        :stripe_invoice_id,
        :amount_due,
        :amount_paid,
        :currency,
        :status,
        :invoice_pdf_url,
        :period_start,
        :period_end,
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
      constraints prefix: "bill"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:invoice) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :stripe_environment, :string, allow_nil?: false, public?: true
    attribute :stripe_invoice_id, :string, allow_nil?: false, public?: true
    attribute :amount_due, :integer, allow_nil?: false, public?: true
    attribute :amount_paid, :integer, allow_nil?: false, public?: true
    attribute :currency, :string, allow_nil?: false, public?: true

    attribute :status, :atom,
      constraints: [one_of: Statuses.invoice()],
      allow_nil?: false,
      public?: true

    attribute :invoice_pdf_url, :string, allow_nil?: true, public?: true
    attribute :period_start, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :period_end, :utc_datetime_usec, allow_nil?: false, public?: true
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
