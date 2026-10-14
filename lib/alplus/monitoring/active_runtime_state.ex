defmodule Alplus.Monitoring.ActiveRuntimeState do
  @moduledoc false

  # This is the scheduler's durable replacement for GenServer-only counters.
  # The outcome writer locks this row with the monitor row before it derives an
  # incident transition, so a scheduler restart cannot reset the threshold.
  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Monitoring,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "active_monitor_runtime_states"
    repo Alplus.Repo

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

    attribute :config_version, :integer, allow_nil?: false, default: 1, public?: false
    attribute :consecutive_failures, :integer, allow_nil?: false, default: 0, public?: false
    attribute :consecutive_recoveries, :integer, allow_nil?: false, default: 0, public?: false
    attribute :last_status, :string, allow_nil?: false, default: "unknown", public?: false
    attribute :last_check_at, :utc_datetime_usec, allow_nil?: true, public?: false
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
