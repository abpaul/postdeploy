defmodule Alplus.Monitoring.Monitor do
  @moduledoc """
  A project-scoped monitor. Type-specific configuration lives in exactly one
  1:1 child resource, never in a presentation-default JSON blob.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Monitoring,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "monitors"
    repo Alplus.Repo

    custom_statements do
      statement :monitor_checks do
        up """
        ALTER TABLE monitors
          ADD CONSTRAINT monitors_type_check CHECK (type IN ('http', 'keyword', 'heartbeat', 'tcp', 'dns')),
          ADD CONSTRAINT monitors_status_check CHECK (status IN ('active', 'paused')),
          ADD CONSTRAINT monitors_last_known_status_check CHECK (last_known_status IN ('up', 'down', 'degraded', 'unknown')),
          ADD CONSTRAINT monitors_name_check CHECK (octet_length(btrim(name)) BETWEEN 1 AND 200),
          ADD CONSTRAINT monitors_environment_check CHECK (environment IS NULL OR octet_length(environment) <= 64),
          ADD CONSTRAINT monitors_failure_threshold_check CHECK (failure_threshold BETWEEN 1 AND 5),
          ADD CONSTRAINT monitors_resend_check CHECK (resend_after_failed_checks BETWEEN 0 AND 100),
          ADD CONSTRAINT monitors_slo_target_check CHECK (slo_target IS NULL OR (slo_target > 0 AND slo_target <= 1)),
          ADD CONSTRAINT monitors_config_version_check CHECK (config_version >= 1)
        """

        down """
        ALTER TABLE monitors
          DROP CONSTRAINT monitors_type_check,
          DROP CONSTRAINT monitors_status_check,
          DROP CONSTRAINT monitors_last_known_status_check,
          DROP CONSTRAINT monitors_name_check,
          DROP CONSTRAINT monitors_environment_check,
          DROP CONSTRAINT monitors_failure_threshold_check,
          DROP CONSTRAINT monitors_resend_check,
          DROP CONSTRAINT monitors_slo_target_check,
          DROP CONSTRAINT monitors_config_version_check
        """
      end
    end

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    read :list_for_project do
      argument :project_id, :string, allow_nil?: false
      filter expr(org_id == ^actor(:org_id) and project_id == ^arg(:project_id))
      pagination keyset?: true, required?: false
    end

    # Vendor designation is the homepage publication decision. This action is
    # reached only through the actor returned by `Changelog.Public.resolve_vendor/0`;
    # it never accepts tenant identifiers and its result set is fixed.
    read :public_homepage_for_vendor do
      filter expr(
               org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                 environment == "production" and status == "active"
             )

      prepare build(
                select: [:id, :name, :type, :last_known_status],
                sort: [name: :asc, id: :asc],
                limit: 20
              )
    end

    # The organization Projects index renders a bounded set of project rows at
    # once. This action is deliberately separate from :list_for_project: its
    # filter is still pinned to the caller's organization and explicit project
    # ids, while its policy below authorizes only an org member.
    read :list_for_projects do
      argument :project_ids, {:array, :string}, allow_nil?: false
      filter expr(org_id == ^actor(:org_id) and project_id in ^arg(:project_ids))
    end

    read :exists_for_projects do
      argument :project_ids, {:array, :string}, allow_nil?: false
      filter expr(org_id == ^actor(:org_id) and project_id in ^arg(:project_ids))
    end

    create :create do
      accept [
        :org_id,
        :project_id,
        :environment,
        :type,
        :name,
        :slo_target,
        :failure_threshold,
        :resend_after_failed_checks
      ]

      validate Alplus.Monitoring.Validations.SloTarget
      change Alplus.Billing.Changes.EnforceMonitorCapacity
    end

    update :update do
      accept [
        :name,
        :environment,
        :status,
        :slo_target,
        :failure_threshold,
        :resend_after_failed_checks
      ]

      require_atomic? false
      change atomic_update(:config_version, expr(config_version + 1))

      validate Alplus.Monitoring.Validations.SloTarget

      # Entitlement gate: an inactive organization (expired trial, lapsed
      # subscription) may not edit monitors. Reads stay open.
      change fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn changeset ->
          case Alplus.Billing.Access.check(Ash.Changeset.get_attribute(changeset, :org_id)) do
            {:ok, _access} -> changeset
            {:error, %{message: message}} -> Ash.Changeset.add_error(changeset, message: message)
          end
        end)
      end

      change Alplus.Monitoring.Monitor.Changes.RecordPauseInterval
      change Alplus.Monitoring.Monitor.Changes.ReconcileScheduler
    end

    destroy :destroy do
    end
  end

  policies do
    policy action([:read, :list_for_project]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action([:list_for_projects, :exists_for_projects]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action(:public_homepage_for_vendor) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       environment == "production" and status == "active"
                   )
    end

    policy action_type([:create, :update, :destroy]) do
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
      constraints prefix: "mon"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:monitor) end
    end

    attribute :org_id, Alplus.Id do
      constraints prefix: "organization"
      allow_nil? false
      public? true
    end

    attribute :project_id, Alplus.Id do
      constraints prefix: "project"
      allow_nil? false
      public? true
    end

    attribute :environment, :string, allow_nil?: true, public?: true

    attribute :type, :string do
      allow_nil? false
      public? true
    end

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :failure_threshold, :integer, allow_nil?: false, default: 2, public?: true
    attribute :resend_after_failed_checks, :integer, allow_nil?: false, default: 0, public?: true
    attribute :slo_target, :float, allow_nil?: true, public?: true
    attribute :status, :string, allow_nil?: false, default: "active", public?: true

    attribute :config_version, :integer,
      allow_nil?: false,
      default: 1,
      public?: true,
      writable?: false

    attribute :last_known_status, :string, allow_nil?: false, default: "unknown", public?: true
    attribute :last_check_at, :utc_datetime_usec, allow_nil?: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :organization, Alplus.Orgs.Organization do
      source_attribute :org_id
      define_attribute? false
      allow_nil? false
    end

    belongs_to :project, Alplus.Projects.Project do
      source_attribute :project_id
      define_attribute? false
      allow_nil? false
    end

    has_one :http_config, Alplus.Monitoring.HttpConfig, destination_attribute: :monitor_id

    has_one :heartbeat_config, Alplus.Monitoring.HeartbeatConfig,
      destination_attribute: :monitor_id

    has_one :tcp_config, Alplus.Monitoring.TcpConfig, destination_attribute: :monitor_id
    has_one :dns_config, Alplus.Monitoring.DnsConfig, destination_attribute: :monitor_id
    has_many :pause_intervals, Alplus.Monitoring.PauseInterval, destination_attribute: :monitor_id
    has_many :checks, Alplus.Monitoring.MonitorCheck, destination_attribute: :monitor_id

    has_one :latest_check, Alplus.Monitoring.MonitorCheck do
      destination_attribute :monitor_id
      sort checked_at: :desc
    end

    has_one :open_incident, Alplus.Monitoring.Incident do
      destination_attribute :monitor_id
      filter expr(status == :open)
      sort started_at: :desc
    end
  end

  calculations do
    calculate :attention_priority,
              :integer,
              expr(
                if status == "active" and last_known_status in ["down", "degraded"] do
                  0
                else
                  if status == "active" and last_known_status == "unknown" do
                    1
                  else
                    if status == "paused", do: 2, else: 3
                  end
                end
              )
  end
end
