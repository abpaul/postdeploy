defmodule Alplus.Monitoring.HeartbeatRuntimeState do
  @moduledoc false

  # Durable state shared by heartbeat ingest and the scheduler. It is not a
  # public domain object; the hot-path service locks and updates its row.
  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Monitoring,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "heartbeat_runtime_states"
    repo Alplus.Repo

    custom_statements do
      statement :runtime_state_checks do
        up """
        ALTER TABLE heartbeat_runtime_states
          ADD CONSTRAINT heartbeat_runtime_states_counts_check CHECK (consecutive_failures >= 0 AND consecutive_passes >= 0)
        """

        down "ALTER TABLE heartbeat_runtime_states DROP CONSTRAINT heartbeat_runtime_states_counts_check"
      end
    end

    references do
      reference :monitor, on_delete: :delete
    end
  end

  actions do
    defaults [:read]
  end

  attributes do
    attribute :monitor_id, Alplus.Id do
      constraints prefix: "mon"
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :pending_start_at, :utc_datetime_usec, allow_nil?: true, public?: false
    attribute :last_heartbeat_at, :utc_datetime_usec, allow_nil?: true, public?: false
    attribute :consecutive_failures, :integer, allow_nil?: false, default: 0, public?: false
    attribute :consecutive_passes, :integer, allow_nil?: false, default: 0, public?: false
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :monitor, Alplus.Monitoring.Monitor,
      source_attribute: :monitor_id,
      define_attribute?: false,
      allow_nil?: false
  end
end
