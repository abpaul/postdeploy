defmodule Alplus.Repo.Migrations.AddBillingSubscriptionMirror do
  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    create table(:stripe_customers, primary_key: false) do
      add :id, :text, null: false, primary_key: true
      add :org_id, references(:organizations, type: :text, on_delete: :delete_all), null: false
      add :stripe_environment, :text, null: false
      add :stripe_customer_id, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:stripe_customers, [:org_id, :stripe_environment])
    create unique_index(:stripe_customers, [:stripe_environment, :stripe_customer_id])

    create table(:subscriptions, primary_key: false) do
      add :id, :text, null: false, primary_key: true
      add :org_id, references(:organizations, type: :text, on_delete: :delete_all), null: false
      add :stripe_environment, :text, null: false
      add :stripe_subscription_id, :text, null: false
      add :plan_id, :text, null: false
      add :status, :text, null: false
      add :current_period_start, :utc_datetime_usec, null: false
      add :current_period_end, :utc_datetime_usec, null: false
      add :cancel_at_period_end, :boolean, null: false, default: false
      add :event_created_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:subscriptions, [:org_id, :stripe_environment])
    create unique_index(:subscriptions, [:stripe_environment, :stripe_subscription_id])

    create table(:invoices, primary_key: false) do
      add :id, :text, null: false, primary_key: true
      add :org_id, references(:organizations, type: :text, on_delete: :delete_all), null: false
      add :stripe_environment, :text, null: false
      add :stripe_invoice_id, :text, null: false
      add :amount_due, :bigint, null: false
      add :amount_paid, :bigint, null: false
      add :currency, :text, null: false
      add :status, :text, null: false
      add :invoice_pdf_url, :text
      add :period_start, :utc_datetime_usec, null: false
      add :period_end, :utc_datetime_usec, null: false
      add :event_created_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:invoices, [:stripe_environment, :stripe_invoice_id])
    create index(:invoices, [:org_id, :inserted_at])

    create table(:stripe_webhook_events, primary_key: false) do
      add :id, :text, null: false, primary_key: true
      add :stripe_environment, :text, null: false
      add :stripe_event_id, :text, null: false
      add :type, :text, null: false
      add :api_version, :text
      add :livemode, :boolean, null: false
      add :payload_hash, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :attempt_count, :integer, null: false, default: 0
      add :claim_token, :text
      add :claim_fence, :bigint, null: false, default: 0
      add :claim_expires_at, :utc_datetime_usec
      add :last_error, :text
      add :received_at, :utc_datetime_usec, null: false
      add :processed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:stripe_webhook_events, [:stripe_environment, :stripe_event_id])
    create index(:stripe_webhook_events, [:received_at])

    create index(:stripe_webhook_events, [:claim_expires_at],
             where: "status IN ('pending', 'processing')"
           )

    execute("""
    ALTER TABLE stripe_customers
      ADD CONSTRAINT stripe_customers_environment_check CHECK (stripe_environment IN ('local', 'preview', 'staging', 'production')),
      ADD CONSTRAINT stripe_customers_external_id_check CHECK (char_length(stripe_customer_id) BETWEEN 1 AND 255)
    """)

    execute("""
    ALTER TABLE subscriptions
      ADD CONSTRAINT subscriptions_environment_check CHECK (stripe_environment IN ('local', 'preview', 'staging', 'production')),
      ADD CONSTRAINT subscriptions_plan_check CHECK (plan_id IN ('indie', 'agency')),
      ADD CONSTRAINT subscriptions_status_check CHECK (status IN ('active', 'past_due', 'canceled', 'incomplete', 'incomplete_expired', 'paused', 'unpaid')),
      ADD CONSTRAINT subscriptions_period_check CHECK (current_period_end > current_period_start),
      ADD CONSTRAINT subscriptions_external_id_check CHECK (char_length(stripe_subscription_id) BETWEEN 1 AND 255)
    """)

    execute("""
    ALTER TABLE invoices
      ADD CONSTRAINT invoices_environment_check CHECK (stripe_environment IN ('local', 'preview', 'staging', 'production')),
      ADD CONSTRAINT invoices_currency_check CHECK (currency ~ '^[a-z]{3}$'),
      ADD CONSTRAINT invoices_status_check CHECK (status IN ('draft', 'open', 'paid', 'uncollectible', 'void')),
      ADD CONSTRAINT invoices_amount_check CHECK (amount_due >= 0 AND amount_paid >= 0),
      ADD CONSTRAINT invoices_period_check CHECK (period_end >= period_start),
      ADD CONSTRAINT invoices_external_id_check CHECK (char_length(stripe_invoice_id) BETWEEN 1 AND 255),
      ADD CONSTRAINT invoices_pdf_url_check CHECK (invoice_pdf_url IS NULL OR char_length(invoice_pdf_url) <= 2048)
    """)

    execute("""
    ALTER TABLE stripe_webhook_events
      ADD CONSTRAINT stripe_webhook_events_environment_check CHECK (stripe_environment IN ('local', 'preview', 'staging', 'production')),
      ADD CONSTRAINT stripe_webhook_events_payload_hash_check CHECK (payload_hash ~ '^[0-9a-f]{64}$'),
      ADD CONSTRAINT stripe_webhook_events_status_check CHECK (status IN ('pending', 'processing', 'processed', 'failed')),
      ADD CONSTRAINT stripe_webhook_events_attempt_check CHECK (attempt_count >= 0 AND claim_fence >= 0),
      ADD CONSTRAINT stripe_webhook_events_error_check CHECK (last_error IS NULL OR octet_length(last_error) <= 4096),
      ADD CONSTRAINT stripe_webhook_events_identity_check CHECK (char_length(stripe_event_id) BETWEEN 1 AND 255 AND char_length(type) BETWEEN 1 AND 255 AND (api_version IS NULL OR char_length(api_version) <= 64)),
      ADD CONSTRAINT stripe_webhook_events_claim_token_check CHECK (claim_token IS NULL OR char_length(claim_token) <= 255),
      ADD CONSTRAINT stripe_webhook_events_claim_check CHECK (status <> 'processing' OR (claim_token IS NOT NULL AND claim_expires_at IS NOT NULL))
    """)
  end

  def down do
    drop table(:stripe_webhook_events)
    drop table(:invoices)
    drop table(:subscriptions)
    drop table(:stripe_customers)
  end
end
