defmodule Alplus.Monitoring.MonitorCheck do
  @moduledoc """
  One immutable monitor result. Scheduler and heartbeat ingest write these
  through a dedicated internal action in the next Phase 6 slice.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Monitoring,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "monitor_checks"
    repo Alplus.Repo

    custom_indexes do
      index [:org_id, :monitor_id, :checked_at]
      index [:org_id, :project_id, :environment, :checked_at]
    end

    custom_statements do
      statement :check_constraints do
        up """
        ALTER TABLE monitor_checks
          ADD CONSTRAINT monitor_checks_status_check CHECK (status IN ('up', 'down', 'degraded')),
          ADD CONSTRAINT monitor_checks_environment_check CHECK (environment IS NULL OR octet_length(environment) <= 64),
          ADD CONSTRAINT monitor_checks_latency_check CHECK (latency_ms IS NULL OR latency_ms >= 0),
          ADD CONSTRAINT monitor_checks_status_code_check CHECK (status_code IS NULL OR status_code BETWEEN 100 AND 599),
          ADD CONSTRAINT monitor_checks_error_class_check CHECK (error_class IS NULL OR octet_length(error_class) <= 128),
          ADD CONSTRAINT monitor_checks_detail_check CHECK (detail IS NULL OR octet_length(detail::text) <= 4096)
        """

        down """
        ALTER TABLE monitor_checks
          DROP CONSTRAINT monitor_checks_status_check,
          DROP CONSTRAINT monitor_checks_environment_check,
          DROP CONSTRAINT monitor_checks_latency_check,
          DROP CONSTRAINT monitor_checks_status_code_check,
          DROP CONSTRAINT monitor_checks_error_class_check,
          DROP CONSTRAINT monitor_checks_detail_check
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

    read :exists_for_projects do
      argument :project_ids, {:array, :string}, allow_nil?: false
      filter expr(org_id == ^actor(:org_id) and project_id in ^arg(:project_ids))
    end

    # Bounded, offset-paginated read for the detail page's recent-checks log
    # (page-size selector + Prev/Next), distinct from the fixed-cap sample
    # read the activity/chart boundary uses. Never loads the full check
    # history into memory.
    read :list_for_monitor do
      argument :monitor_id, :string, allow_nil?: false
      filter expr(monitor_id == ^arg(:monitor_id))
      pagination offset?: true, countable: true, required?: false, default_limit: 5
    end

    # The homepage exposes one bounded, recent production check sample.
    # It intentionally does not imply a per-monitor or 24-hour aggregate.
    read :public_homepage_for_vendor do
      argument :monitor_ids, {:array, :string}, allow_nil?: false

      filter expr(
               org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                 monitor_id in ^arg(:monitor_ids) and environment == "production"
             )

      prepare build(
                select: [:monitor_id, :status, :checked_at, :latency_ms],
                sort: [checked_at: :desc, id: :desc],
                limit: 1
              )
    end

    create :record do
      accept [
        :org_id,
        :project_id,
        :monitor_id,
        :environment,
        :status,
        :checked_at,
        :status_code,
        :latency_ms,
        :error_class,
        :detail
      ]
    end
  end

  policies do
    policy action([:read, :list_for_monitor]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action(:exists_for_projects) do
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

    # The scheduler and heartbeat boundary run this internal action with a
    # system actor. Browser and API scopes cannot write raw check history.
    policy action(:record) do
      forbid_if always()
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "chk"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:monitor_check) end
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
    attribute :status, :string, allow_nil?: false, public?: true
    attribute :checked_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :status_code, :integer, allow_nil?: true, public?: true
    attribute :latency_ms, :integer, allow_nil?: true, public?: true
    attribute :error_class, :string, allow_nil?: true, public?: true
    attribute :detail, :map, allow_nil?: true, public?: true
    create_timestamp :inserted_at
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
