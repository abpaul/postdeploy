defmodule Alplus.Repo.Migrations.RefactorPlansToTrialIndieProScale do
  @trial_days Alplus.Billing.Package.trial_days()

  @moduledoc """
  Moves organizations and subscriptions onto the trial/indie/pro/scale
  registry (issue #61, items 1-5 and 21-22).

  Existing free organizations become trialing trials with a #{@trial_days}-day clock, so
  nobody loses access on deploy day. Paid plans keep their tier with
  `agency` renamed to `pro`. Every paid organization carries a past
  `trial_ends_at` that is never consulted while the plan is active.

  The old check constraints forbid `'pro'` and `'trial'`, and the new ones
  forbid `'free'` and `'agency'`, so both directions drop the constraint
  before rewriting rows and re-add it after.
  """

  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    execute("ALTER TABLE organizations ADD COLUMN trial_ends_at timestamptz")

    execute("ALTER TABLE organizations DROP CONSTRAINT organizations_plan_check")
    execute("ALTER TABLE subscriptions DROP CONSTRAINT subscriptions_plan_check")

    execute("""
    UPDATE organizations
       SET plan_id = 'pro'
     WHERE plan_id = 'agency'
    """)

    execute("""
    UPDATE subscriptions
       SET plan_id = 'pro'
     WHERE plan_id = 'agency'
    """)

    execute("""
    UPDATE organizations
       SET plan_id = 'trial',
           plan_status = 'trialing',
           trial_ends_at = now() + make_interval(days => #{@trial_days})
     WHERE plan_id = 'free'
    """)

    execute("""
    UPDATE organizations
       SET trial_ends_at = inserted_at
     WHERE plan_id IN ('indie', 'pro', 'scale')
    """)

    execute("ALTER TABLE organizations ALTER COLUMN trial_ends_at SET NOT NULL")

    execute("""
    ALTER TABLE organizations
      ADD CONSTRAINT organizations_plan_check_new
      CHECK (plan_id IN ('trial', 'indie', 'pro', 'scale')) NOT VALID
    """)

    execute("ALTER TABLE organizations VALIDATE CONSTRAINT organizations_plan_check_new")

    execute(
      "ALTER TABLE organizations RENAME CONSTRAINT organizations_plan_check_new TO organizations_plan_check"
    )

    execute("""
    ALTER TABLE subscriptions
      ADD CONSTRAINT subscriptions_plan_check_new
      CHECK (plan_id IN ('indie', 'pro', 'scale')) NOT VALID
    """)

    execute("ALTER TABLE subscriptions VALIDATE CONSTRAINT subscriptions_plan_check_new")

    execute(
      "ALTER TABLE subscriptions RENAME CONSTRAINT subscriptions_plan_check_new TO subscriptions_plan_check"
    )
  end

  def down do
    execute("SET lock_timeout = '3s'")

    execute("ALTER TABLE organizations DROP CONSTRAINT organizations_plan_check")
    execute("ALTER TABLE subscriptions DROP CONSTRAINT subscriptions_plan_check")

    execute("""
    UPDATE organizations
       SET plan_id = 'agency'
     WHERE plan_id IN ('pro', 'scale')
    """)

    execute("""
    UPDATE subscriptions
       SET plan_id = 'agency'
     WHERE plan_id IN ('pro', 'scale')
    """)

    execute("""
    UPDATE organizations
       SET plan_id = 'free',
           plan_status = 'active'
     WHERE plan_id = 'trial'
    """)

    execute("""
    ALTER TABLE organizations
      ADD CONSTRAINT organizations_plan_check_old
      CHECK (plan_id IN ('free', 'indie', 'agency')) NOT VALID
    """)

    execute("ALTER TABLE organizations VALIDATE CONSTRAINT organizations_plan_check_old")

    execute(
      "ALTER TABLE organizations RENAME CONSTRAINT organizations_plan_check_old TO organizations_plan_check"
    )

    execute("""
    ALTER TABLE subscriptions
      ADD CONSTRAINT subscriptions_plan_check_old
      CHECK (plan_id IN ('indie', 'agency')) NOT VALID
    """)

    execute("ALTER TABLE subscriptions VALIDATE CONSTRAINT subscriptions_plan_check_old")

    execute(
      "ALTER TABLE subscriptions RENAME CONSTRAINT subscriptions_plan_check_old TO subscriptions_plan_check"
    )

    execute("ALTER TABLE organizations DROP COLUMN trial_ends_at")
  end
end
