defmodule Alplus.Monitoring.DailyRollup do
  @moduledoc """
  One monitor's durable, time-weighted availability result for a UTC day.

  Detailed checks are short-lived. Daily rollups retain the result calculated
  from incidents, so their uptime is not biased by an arbitrary check cadence.
  The telemetry maintenance path writes this resource through `Rollup`.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Monitoring,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "monitor_daily_rollups"
    repo Alplus.Repo

    custom_indexes do
      index [:monitor_id, :day], unique: true, name: "monitor_daily_rollups_monitor_day_index"
      index [:org_id, :project_id, :day]
    end

    custom_statements do
      statement :daily_rollup_constraints do
        up """
        ALTER TABLE monitor_daily_rollups
          ADD CONSTRAINT monitor_daily_rollups_duration_check CHECK (
            monitored_microseconds >= 0 AND downtime_microseconds >= 0 AND
            downtime_microseconds <= monitored_microseconds
          ),
          ADD CONSTRAINT monitor_daily_rollups_uptime_check CHECK (
            uptime_ratio IS NULL OR (uptime_ratio >= 0 AND uptime_ratio <= 1)
          ),
          ADD CONSTRAINT monitor_daily_rollups_check_count_check CHECK (check_count >= 0),
          ADD CONSTRAINT monitor_daily_rollups_environment_check CHECK (
            environment IS NULL OR octet_length(environment) <= 64
          )
        """

        down """
        ALTER TABLE monitor_daily_rollups
          DROP CONSTRAINT monitor_daily_rollups_duration_check,
          DROP CONSTRAINT monitor_daily_rollups_uptime_check,
          DROP CONSTRAINT monitor_daily_rollups_check_count_check,
          DROP CONSTRAINT monitor_daily_rollups_environment_check
        """
      end
    end

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :monitor, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    # Bounded organization project-index read. The explicit project id list is
    # required so this action cannot become an unbounded org health query.
    read :list_for_projects do
      argument :project_ids, {:array, :string}, allow_nil?: false
      filter expr(org_id == ^actor(:org_id) and project_id in ^arg(:project_ids))
    end

    # The monitor ids originate from the separately capped vendor monitor
    # action. The result cap bounds the full history sample before it reaches
    # the homepage projection.
    read :public_homepage_for_vendor do
      argument :monitor_ids, {:array, :string}, allow_nil?: false
      argument :since, :date, allow_nil?: false
      argument :until, :date, allow_nil?: false

      filter expr(
               org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                 monitor_id in ^arg(:monitor_ids) and environment == "production" and
                 day >= ^arg(:since) and day < ^arg(:until)
             )

      prepare build(
                select: [
                  :monitor_id,
                  :day,
                  :uptime_ratio,
                  :monitored_microseconds,
                  :downtime_microseconds
                ],
                sort: [day: :desc, id: :desc],
                limit: 1800
              )
    end
  end

  policies do
    policy action(:read) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action(:list_for_projects) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action(:public_homepage_for_vendor) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       environment == "production"
                   )
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "roll"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:monitor_check_rollup) end
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
    attribute :day, :date, allow_nil?: false, public?: true
    attribute :uptime_ratio, :float, allow_nil?: true, public?: true
    attribute :monitored_microseconds, :integer, allow_nil?: false, public?: true
    attribute :downtime_microseconds, :integer, allow_nil?: false, public?: true
    attribute :check_count, :integer, allow_nil?: false, public?: true
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
  end
end
