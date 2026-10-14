defmodule Alplus.Growth.DailyCount do
  @moduledoc """
  Aggregate health-check funnel counts kept after journey events expire.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Growth,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "growth_health_check_daily_counts"
    repo Alplus.Repo

    custom_statements do
      statement :stage_enum_check do
        up "ALTER TABLE growth_health_check_daily_counts ADD CONSTRAINT growth_health_check_daily_counts_stage_enum_check CHECK (stage IN ('health_check_started', 'health_check_result_produced', 'signup', 'configured', 'activated'))"

        down "ALTER TABLE growth_health_check_daily_counts DROP CONSTRAINT growth_health_check_daily_counts_stage_enum_check"
      end
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [:day, :stage, :count]
      upsert? true
      upsert_identity :unique_day_stage
      upsert_fields [:count]
    end
  end

  policies do
    policy always() do
      forbid_if always()
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "gdc"
      public? true
      writable? false
      primary_key? true
      allow_nil? false
      default fn -> Alplus.Id.generate("gdc") end
    end

    attribute :day, :date do
      allow_nil? false
      public? true
    end

    attribute :stage, :string do
      allow_nil? false
      public? true
      constraints max_length: 64
    end

    attribute :count, :integer do
      allow_nil? false
      public? true
      default 0
    end
  end

  identities do
    identity :unique_day_stage, [:day, :stage]
  end
end
