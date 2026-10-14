defmodule Alplus.Repo.Migrations.AddTrialingSubscriptionStatus do
  @moduledoc """
  Expands the Stripe mirror status vocabulary without changing existing rows.

  The replacement constraint is validated before the old constraint is
  removed, so rolling application versions continue to accept their existing
  seven-status subset during deployment.
  """

  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    execute("""
    ALTER TABLE subscriptions
      ADD CONSTRAINT subscriptions_status_check_v2
      CHECK (status IN ('active', 'past_due', 'canceled', 'incomplete', 'incomplete_expired', 'paused', 'trialing', 'unpaid')) NOT VALID
    """)

    execute("ALTER TABLE subscriptions VALIDATE CONSTRAINT subscriptions_status_check_v2")
    execute("ALTER TABLE subscriptions DROP CONSTRAINT subscriptions_status_check")

    execute(
      "ALTER TABLE subscriptions RENAME CONSTRAINT subscriptions_status_check_v2 TO subscriptions_status_check"
    )
  end

  def down do
    execute("SET lock_timeout = '3s'")

    execute("""
    ALTER TABLE subscriptions
      ADD CONSTRAINT subscriptions_status_check_v2
      CHECK (status IN ('active', 'past_due', 'canceled', 'incomplete', 'incomplete_expired', 'paused', 'unpaid')) NOT VALID
    """)

    execute("ALTER TABLE subscriptions VALIDATE CONSTRAINT subscriptions_status_check_v2")
    execute("ALTER TABLE subscriptions DROP CONSTRAINT subscriptions_status_check")

    execute(
      "ALTER TABLE subscriptions RENAME CONSTRAINT subscriptions_status_check_v2 TO subscriptions_status_check"
    )
  end
end
