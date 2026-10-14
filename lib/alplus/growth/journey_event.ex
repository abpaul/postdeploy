defmodule Alplus.Growth.JourneyEvent do
  @moduledoc """
  One anonymous health-check funnel stage, keyed by a random journey id.

  No target URL, response body, DNS answer, or result detail is stored.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Growth,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "growth_journey_events"
    repo Alplus.Repo

    custom_indexes do
      index [:journey_id]
      index [:inserted_at]
    end

    custom_statements do
      statement :journey_id_length_check do
        up "ALTER TABLE growth_journey_events ADD CONSTRAINT growth_journey_events_journey_id_length_check CHECK (octet_length(journey_id) <= 64)"

        down "ALTER TABLE growth_journey_events DROP CONSTRAINT growth_journey_events_journey_id_length_check"
      end

      statement :stage_enum_check do
        up "ALTER TABLE growth_journey_events ADD CONSTRAINT growth_journey_events_stage_enum_check CHECK (stage IN ('health_check_started', 'health_check_result_produced', 'signup', 'configured', 'activated'))"

        down "ALTER TABLE growth_journey_events DROP CONSTRAINT growth_journey_events_stage_enum_check"
      end

      statement :user_id_length_check do
        up "ALTER TABLE growth_journey_events ADD CONSTRAINT growth_journey_events_user_id_length_check CHECK (user_id IS NULL OR octet_length(user_id) <= 50)"

        down "ALTER TABLE growth_journey_events DROP CONSTRAINT growth_journey_events_user_id_length_check"
      end
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [:journey_id, :stage, :user_id]
      upsert? true
      upsert_identity :unique_journey_stage
    end
  end

  policies do
    policy always() do
      forbid_if always()
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "gje"
      public? true
      writable? false
      primary_key? true
      allow_nil? false
      default fn -> Alplus.Id.generate("gje") end
    end

    attribute :journey_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 64
    end

    attribute :stage, :string do
      allow_nil? false
      public? true
      constraints max_length: 64
    end

    attribute :user_id, :string do
      public? true
      constraints max_length: 50
    end

    create_timestamp :inserted_at
  end

  identities do
    identity :unique_journey_stage, [:journey_id, :stage]
  end
end
