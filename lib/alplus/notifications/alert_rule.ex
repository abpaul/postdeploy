defmodule Alplus.Notifications.AlertRule do
  @moduledoc """
  A project-scoped routing rule from an Observe or Monitor event to a channel.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Notifications,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "alert_rules"
    repo Alplus.Repo

    custom_indexes do
      index [:org_id, :project_id, :module]
    end

    custom_statements do
      statement :alert_rule_constraints do
        up """
        ALTER TABLE alert_rules
          ADD CONSTRAINT alert_rules_module_check CHECK (module IN ('observe', 'monitor')),
          ADD CONSTRAINT alert_rules_trigger_check CHECK (
            (module = 'observe' AND trigger_type IN ('new_issue', 'issue_regression', 'error_spike', 'quota')) OR
            (module = 'monitor' AND trigger_type IN ('check_down', 'check_recovered', 'ssl_expiring', 'domain_expiring'))
          ),
          ADD CONSTRAINT alert_rules_condition_check CHECK (condition IS NULL OR octet_length(condition::text) <= 4096)
        """

        down """
        ALTER TABLE alert_rules
          DROP CONSTRAINT alert_rules_module_check,
          DROP CONSTRAINT alert_rules_trigger_check,
          DROP CONSTRAINT alert_rules_condition_check
        """
      end
    end

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :channel, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    read :list_for_project do
      argument :project_id, :string, allow_nil?: false
      filter expr(org_id == ^actor(:org_id) and project_id == ^arg(:project_id))
    end

    create :create do
      accept [:org_id, :project_id, :module, :trigger_type, :condition, :channel_id, :enabled]
      validate Alplus.Notifications.Validations.RelationshipsInOrg
    end

    update :update do
      accept [:module, :trigger_type, :condition, :channel_id, :enabled]
      require_atomic? false
      validate Alplus.Notifications.Validations.RelationshipsInOrg
    end

    destroy :destroy do
      require_atomic? false
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
      constraints prefix: "rule"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:alert_rule) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :project_id, Alplus.Id,
      constraints: [prefix: "project"],
      allow_nil?: false,
      public?: true

    attribute :module, :string, allow_nil?: false, public?: true
    attribute :trigger_type, :string, allow_nil?: false, public?: true
    attribute :condition, :map, allow_nil?: true, public?: true

    attribute :channel_id, Alplus.Id,
      constraints: [prefix: "chan"],
      allow_nil?: false,
      public?: true

    attribute :enabled, :boolean, allow_nil?: false, default: true, public?: true
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

    belongs_to :channel, Alplus.Notifications.Channel,
      source_attribute: :channel_id,
      define_attribute?: false,
      allow_nil?: false
  end
end
