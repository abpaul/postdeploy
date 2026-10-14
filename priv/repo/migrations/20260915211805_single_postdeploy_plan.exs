defmodule Alplus.Repo.Migrations.SinglePostdeployPlan do
  @moduledoc """
  Replaces the Indie, Pro and Scale plans with the one `postdeploy` plan,
  billed monthly.

  No customer paid for a retired plan when this shipped (founder decision,
  2026-09-16), so every non-trial organization and every mirrored subscription
  moves to `postdeploy` and to monthly billing. The old check constraints
  forbid the new values and the new ones forbid the old values, so both
  directions drop the constraints before they rewrite rows. `down` cannot
  restore which retired plan a row held; it maps every paid row to `indie`.
  """

  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    execute("ALTER TABLE organizations DROP CONSTRAINT organizations_plan_check")
    execute("ALTER TABLE subscriptions DROP CONSTRAINT subscriptions_plan_check")
    execute("ALTER TABLE subscriptions DROP CONSTRAINT subscriptions_billing_interval_check")

    execute("UPDATE organizations SET plan_id = 'postdeploy' WHERE plan_id <> 'trial'")

    execute("""
    UPDATE subscriptions
       SET plan_id = 'postdeploy',
           billing_interval = 'monthly'
     WHERE plan_id <> 'postdeploy' OR billing_interval <> 'monthly'
    """)

    execute("ALTER TABLE subscriptions ALTER COLUMN billing_interval SET DEFAULT 'monthly'")

    add_check("organizations", "organizations_plan_check", "plan_id IN ('trial', 'postdeploy')")
    add_check("subscriptions", "subscriptions_plan_check", "plan_id IN ('postdeploy')")

    add_check(
      "subscriptions",
      "subscriptions_billing_interval_check",
      "billing_interval IN ('monthly')"
    )
  end

  def down do
    execute("SET lock_timeout = '3s'")

    execute("ALTER TABLE organizations DROP CONSTRAINT organizations_plan_check")
    execute("ALTER TABLE subscriptions DROP CONSTRAINT subscriptions_plan_check")
    execute("ALTER TABLE subscriptions DROP CONSTRAINT subscriptions_billing_interval_check")

    execute("UPDATE organizations SET plan_id = 'indie' WHERE plan_id = 'postdeploy'")
    execute("UPDATE subscriptions SET plan_id = 'indie' WHERE plan_id = 'postdeploy'")

    add_check(
      "organizations",
      "organizations_plan_check",
      "plan_id IN ('trial', 'indie', 'pro', 'scale')"
    )

    add_check("subscriptions", "subscriptions_plan_check", "plan_id IN ('indie', 'pro', 'scale')")

    add_check(
      "subscriptions",
      "subscriptions_billing_interval_check",
      "billing_interval IN ('monthly', 'annual')"
    )
  end

  defp add_check(table, name, expression) do
    execute("ALTER TABLE #{table} ADD CONSTRAINT #{name} CHECK (#{expression}) NOT VALID")
    execute("ALTER TABLE #{table} VALIDATE CONSTRAINT #{name}")
  end
end
