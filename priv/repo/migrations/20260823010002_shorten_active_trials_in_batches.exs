defmodule Alplus.Repo.Migrations.ShortenActiveTrialsInBatches do
  @moduledoc "Shortens legacy active-trial rows without one unbounded update transaction."

  use Ecto.Migration

  @disable_ddl_transaction true
  @trial_days Alplus.Billing.Package.trial_days()
  @batch_size 500
  @max_batches 100

  def up do
    execute("SET lock_timeout = '3s'")
    execute("SET statement_timeout = '5s'")

    Enum.each(1..@max_batches, fn _batch ->
      execute("""
      WITH candidates AS (
        SELECT organizations.id,
               claims.started_at + make_interval(days => #{@trial_days}) AS shortened_end
          FROM organizations
          JOIN memberships
            ON memberships.org_id = organizations.id
           AND memberships.role = 'owner'
          JOIN billing_trial_claims AS claims
            ON claims.user_id = memberships.user_id
         WHERE organizations.plan_id = 'trial'
           AND organizations.plan_status = 'trialing'
           AND organizations.trial_ends_at >
               claims.started_at + make_interval(days => #{@trial_days})
         ORDER BY organizations.id
         FOR UPDATE OF organizations SKIP LOCKED
         LIMIT #{@batch_size}
      )
      UPDATE organizations
         SET trial_ends_at = candidates.shortened_end
        FROM candidates
       WHERE organizations.id = candidates.id
      """)
    end)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
          FROM organizations
          JOIN memberships
            ON memberships.org_id = organizations.id
           AND memberships.role = 'owner'
          JOIN billing_trial_claims AS claims
            ON claims.user_id = memberships.user_id
         WHERE organizations.plan_id = 'trial'
           AND organizations.plan_status = 'trialing'
           AND organizations.trial_ends_at >
               claims.started_at + make_interval(days => #{@trial_days})
      ) THEN
        RAISE EXCEPTION 'active trial backfill exceeded #{@batch_size * @max_batches} rows';
      END IF;
    END
    $$
    """)

    execute("SET statement_timeout = 0")
    execute("SET lock_timeout = 0")
  end

  def down, do: :ok
end
