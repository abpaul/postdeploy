defmodule Alplus.Billing.TrialClaim do
  @moduledoc """
  The durable start time of an account's one free trial.

  The row belongs to the user, not an organization. Deleting an organization
  cannot reset the trial clock. Replayed claims return the original row.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Billing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "billing_trial_claims"
    repo Alplus.Repo
  end

  actions do
    defaults [:read]

    create :claim do
      accept [:user_id]
      upsert? true
      upsert_identity :unique_user
      upsert_fields []
    end
  end

  policies do
    policy always() do
      forbid_if always()
    end
  end

  attributes do
    attribute :user_id, :string do
      allow_nil? false
      public? true
      primary_key? true
      constraints max_length: 50
    end

    create_timestamp :started_at
  end

  identities do
    identity :unique_user, [:user_id]
  end
end
