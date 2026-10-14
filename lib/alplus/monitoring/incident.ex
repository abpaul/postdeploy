defmodule Alplus.Monitoring.Incident do
  @moduledoc """
  A monitor outage. `AshStateMachine` owns only its durable `open → resolved`
  transition; scheduler counters stay in the scheduler process.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Monitoring,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine]

  postgres do
    table "incidents"
    repo Alplus.Repo

    custom_indexes do
      index [:monitor_id],
        unique: true,
        where: "status = 'open'",
        name: "incidents_one_open_monitor_index"

      index [:org_id, :monitor_id, :started_at]
      index [:org_id, :project_id, :environment, :status, :started_at]
    end

    custom_statements do
      statement :incident_constraints do
        up """
        ALTER TABLE incidents
          ADD CONSTRAINT incidents_cause_check CHECK (cause IN ('availability', 'heartbeat')),
          ADD CONSTRAINT incidents_environment_check CHECK (environment IS NULL OR octet_length(environment) <= 64),
          ADD CONSTRAINT incidents_detail_check CHECK (octet_length(cause_detail::text) <= 4096),
          ADD CONSTRAINT incidents_failed_checks_check CHECK (checks_failed_count >= 0),
          ADD CONSTRAINT incidents_duration_check CHECK (duration_seconds IS NULL OR duration_seconds >= 0),
          ADD CONSTRAINT incidents_resolution_check CHECK ((status = 'open' AND resolved_at IS NULL AND duration_seconds IS NULL) OR (status = 'resolved' AND resolved_at IS NOT NULL AND duration_seconds IS NOT NULL)),
          ADD CONSTRAINT incidents_acknowledgement_check CHECK ((acknowledged_at IS NULL AND acknowledged_by_id IS NULL) OR (acknowledged_at IS NOT NULL AND acknowledged_by_id IS NOT NULL))
        """

        down """
        ALTER TABLE incidents
          DROP CONSTRAINT incidents_cause_check,
          DROP CONSTRAINT incidents_environment_check,
          DROP CONSTRAINT incidents_detail_check,
          DROP CONSTRAINT incidents_failed_checks_check,
          DROP CONSTRAINT incidents_duration_check,
          DROP CONSTRAINT incidents_resolution_check,
          DROP CONSTRAINT incidents_acknowledgement_check
        """
      end
    end

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :monitor, on_delete: :delete
      reference :acknowledged_by, on_delete: :nilify
    end
  end

  state_machine do
    state_attribute :status
    initial_states [:open]
    default_initial_state :open

    transitions do
      transition :resolve, from: :open, to: :resolved
    end
  end

  actions do
    defaults [:read]

    create :open do
      accept [
        :org_id,
        :project_id,
        :monitor_id,
        :environment,
        :cause,
        :cause_detail,
        :started_at,
        :checks_failed_count
      ]
    end

    update :resolve do
      accept []
      require_atomic? false

      argument :resolved_at, :utc_datetime_usec, allow_nil?: false
      argument :duration_seconds, :integer, allow_nil?: false

      change transition_state(:resolved)
      change set_attribute(:resolved_at, arg(:resolved_at))
      change set_attribute(:duration_seconds, arg(:duration_seconds))
    end

    update :continue do
      accept []
      require_atomic? false

      argument :checks_failed_count, :integer, allow_nil?: false
      argument :cause_detail, :map, allow_nil?: false

      change set_attribute(:checks_failed_count, arg(:checks_failed_count))
      change set_attribute(:cause_detail, arg(:cause_detail))
    end

    update :acknowledge do
      accept []
      require_atomic? false
      validate attribute_equals(:status, :open)
      validate attribute_equals(:acknowledged_at, nil)
      change set_attribute(:acknowledged_at, &DateTime.utc_now/0)
      change relate_actor(:acknowledged_by, field: :user_id, allow_nil?: false)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action(:acknowledge) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:user_id) and role in ["owner", "admin"]
                       )
                   )
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "inc"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:incident) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :project_id, Alplus.Id,
      constraints: [prefix: "project"],
      allow_nil?: false,
      public?: true

    attribute :monitor_id, Alplus.Id,
      constraints: [prefix: "mon"],
      allow_nil?: false,
      public?: true

    attribute :environment, :string, allow_nil?: true, public?: true
    attribute :cause, :string, allow_nil?: false, public?: true
    attribute :cause_detail, :map, allow_nil?: false, default: %{}, public?: true

    attribute :triggering_check_id, Alplus.Id,
      constraints: [prefix: "chk"],
      allow_nil?: true,
      public?: true

    attribute :resolved_by_check_id, Alplus.Id,
      constraints: [prefix: "chk"],
      allow_nil?: true,
      public?: true

    attribute :started_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :resolved_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :duration_seconds, :integer, allow_nil?: true, public?: true
    attribute :checks_failed_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :acknowledged_at, :utc_datetime_usec, allow_nil?: true, public?: true

    attribute :acknowledged_by_id, Alplus.Id,
      constraints: [prefix: "user"],
      allow_nil?: true,
      public?: true,
      writable?: false

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :organization, Alplus.Orgs.Organization,
      source_attribute: :org_id,
      define_attribute?: false,
      allow_nil?: false

    belongs_to :project, Alplus.Projects.Project,
      source_attribute: :project_id,
      define_attribute?: false,
      allow_nil?: false

    belongs_to :monitor, Alplus.Monitoring.Monitor,
      source_attribute: :monitor_id,
      define_attribute?: false,
      allow_nil?: false

    belongs_to :acknowledged_by, Alplus.Accounts.User,
      source_attribute: :acknowledged_by_id,
      define_attribute?: false,
      allow_nil?: true
  end
end
