defmodule Alplus.Analytics.Settings do
  @moduledoc """
  One project's product-analytics configuration (ADR 0007).

  It holds the activation definition and the funnel the overview draws.
  Activation is two event names and a window: the people who did
  `activation_start_event`, and how many of them went on to do
  `activation_event` inside `activation_window_hours`.

  The columns are deliberately separate rather than one blob, so a compound
  activation rule (spec §16, "2 meals logged AND 1 check-in within 48 hours")
  can arrive later as new columns without moving these.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Analytics,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "product_analytics_settings"
    repo Alplus.Repo

    custom_statements do
      statement :product_analytics_settings_checks do
        up """
        ALTER TABLE product_analytics_settings
          ADD CONSTRAINT product_analytics_settings_start_check CHECK (
            activation_start_event IS NULL OR octet_length(activation_start_event) BETWEEN 1 AND 120
          ),
          ADD CONSTRAINT product_analytics_settings_event_check CHECK (
            activation_event IS NULL OR octet_length(activation_event) BETWEEN 1 AND 120
          ),
          ADD CONSTRAINT product_analytics_settings_window_check CHECK (
            activation_window_hours BETWEEN 1 AND 2160
          )
        """

        down """
        ALTER TABLE product_analytics_settings
          DROP CONSTRAINT product_analytics_settings_start_check,
          DROP CONSTRAINT product_analytics_settings_event_check,
          DROP CONSTRAINT product_analytics_settings_window_check
        """
      end
    end

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :primary_funnel, on_delete: :nilify
    end
  end

  actions do
    defaults [:read]

    read :get_for_project do
      get? true
      argument :project_id, :string, allow_nil?: false
      filter expr(org_id == ^actor(:org_id) and project_id == ^arg(:project_id))
    end

    # One row per project, so configuring activation twice updates rather
    # than fails. The caller never has to know whether a row exists.
    create :upsert do
      primary? true
      upsert? true
      upsert_identity :unique_project

      accept [
        :org_id,
        :project_id,
        :activation_start_event,
        :activation_event,
        :activation_window_hours,
        :primary_funnel_id
      ]

      upsert_fields [
        :activation_start_event,
        :activation_event,
        :activation_window_hours,
        :primary_funnel_id
      ]

      validate Alplus.Analytics.Settings.Validations.Activation

      change {Alplus.Audit.Change,
              action: "analytics_settings.configure",
              subject_type: "product_analytics_settings",
              project_id_attribute: :project_id}
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:user_id) and role in ["owner", "admin"]
                       )
                   )
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "pana"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:product_analytics_settings) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :project_id, Alplus.Id,
      constraints: [prefix: "project"],
      allow_nil?: false,
      public?: true

    attribute :activation_start_event, :string, public?: true, constraints: [max_length: 120]
    attribute :activation_event, :string, public?: true, constraints: [max_length: 120]

    attribute :activation_window_hours, :integer,
      allow_nil?: false,
      public?: true,
      default: 168,
      constraints: [min: 1, max: 2160]

    attribute :primary_funnel_id, Alplus.Id,
      constraints: [prefix: "pfun"],
      public?: true

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

    belongs_to :primary_funnel, Alplus.Analytics.Funnel do
      source_attribute :primary_funnel_id
      define_attribute? false
      allow_nil? true
    end
  end

  identities do
    identity :unique_project, [:project_id]
  end
end
