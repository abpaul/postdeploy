defmodule Alplus.Repo.Migrations.AddBillingTrialClaims do
  @trial_days Alplus.Billing.Package.trial_days()

  use Ecto.Migration

  def up do
    create table(:billing_trial_claims, primary_key: false) do
      add :user_id,
          references(:users,
            column: :id,
            name: "billing_trial_claims_user_id_fkey",
            type: :text,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false,
          primary_key: true

      add :started_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:billing_trial_claims, [:user_id],
             name: "billing_trial_claims_unique_user_index"
           )

    execute("""
    INSERT INTO billing_trial_claims (user_id, started_at)
    SELECT m.user_id,
           min(
             CASE
               WHEN o.plan_id = 'trial'
                 THEN o.trial_ends_at - make_interval(days => #{@trial_days})
               ELSE least(
                 o.trial_ends_at,
                 now() - make_interval(days => #{@trial_days})
               )
             END
           )
      FROM memberships m
      JOIN organizations o ON o.id = m.org_id
     WHERE m.role = 'owner'
     GROUP BY m.user_id
    ON CONFLICT (user_id) DO NOTHING
    """)
  end

  def down do
    drop_if_exists unique_index(:billing_trial_claims, [:user_id],
                     name: "billing_trial_claims_unique_user_index"
                   )

    drop table(:billing_trial_claims)
  end
end
