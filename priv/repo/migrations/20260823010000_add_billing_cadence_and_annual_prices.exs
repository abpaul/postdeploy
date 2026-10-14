defmodule Alplus.Repo.Migrations.AddBillingCadenceAndAnnualPrices do
  @moduledoc """
  Records whether a Stripe subscription renews monthly or annually.

  The plan registry owns the price amounts and lookup keys. This migration
  stores only the cadence needed to render the local billing mirror.
  """

  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    alter table(:subscriptions) do
      # Keep the default for rolling deploy compatibility. Add the column as
      # nullable first so the not-null contract can use a separate lock-safe
      # migration after the existing values have been validated.
      add :billing_interval, :text, default: "monthly"
    end

    execute("""
    ALTER TABLE subscriptions
      ADD CONSTRAINT subscriptions_billing_interval_check
      CHECK (billing_interval IN ('monthly', 'annual')) NOT VALID
    """)

    execute("ALTER TABLE subscriptions VALIDATE CONSTRAINT subscriptions_billing_interval_check")
  end

  def down do
    execute("SET lock_timeout = '3s'")
    execute("ALTER TABLE subscriptions DROP CONSTRAINT subscriptions_billing_interval_check")

    alter table(:subscriptions) do
      remove :billing_interval
    end
  end
end
