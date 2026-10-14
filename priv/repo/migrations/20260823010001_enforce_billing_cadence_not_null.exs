defmodule Alplus.Repo.Migrations.EnforceBillingCadenceNotNull do
  @moduledoc "Enforces the cadence contract after the column and value check exist."

  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    execute("""
    ALTER TABLE subscriptions
      ADD CONSTRAINT subscriptions_billing_interval_not_null
      CHECK (billing_interval IS NOT NULL) NOT VALID
    """)

    execute(
      "ALTER TABLE subscriptions VALIDATE CONSTRAINT subscriptions_billing_interval_not_null"
    )

    # PostgreSQL uses the validated check to avoid another table scan. The
    # remaining AccessExclusive lock only changes column metadata.
    execute("ALTER TABLE subscriptions ALTER COLUMN billing_interval SET NOT NULL")
    execute("ALTER TABLE subscriptions DROP CONSTRAINT subscriptions_billing_interval_not_null")
    execute("SET lock_timeout = 0")
  end

  def down do
    execute("ALTER TABLE subscriptions ALTER COLUMN billing_interval DROP NOT NULL")
  end
end
