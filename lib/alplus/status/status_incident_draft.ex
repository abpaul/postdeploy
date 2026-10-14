defmodule Alplus.Status.StatusIncidentDraft do
  @moduledoc "Server-side composer state for a customer-facing incident."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Status,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "status_incident_drafts"
    repo Alplus.Repo

    custom_statements do
      statement :status_incident_draft_constraints do
        up """
        ALTER TABLE status_incident_drafts
          ADD CONSTRAINT status_incident_drafts_title_check CHECK (octet_length(btrim(title)) BETWEEN 1 AND 200),
          ADD CONSTRAINT status_incident_drafts_body_check CHECK (octet_length(body) BETWEEN 1 AND 32768)
        """

        down """
        ALTER TABLE status_incident_drafts
          DROP CONSTRAINT status_incident_drafts_title_check,
          DROP CONSTRAINT status_incident_drafts_body_check
        """
      end
    end

    custom_indexes do
      index [:org_id, :project_id, :status_page_id]
    end

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :status_page, on_delete: :delete
      reference :monitor, on_delete: :delete
      reference :status_incident, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    destroy :destroy do
      primary? true
      require_atomic? false

      change {Alplus.Audit.Change,
              action: "status_incident_draft.destroy",
              subject_type: "status_incident_draft",
              project_id_attribute: :project_id}
    end

    read :for_incident do
      argument :status_incident_id, :string, allow_nil?: false

      filter expr(
               status_incident_id == ^arg(:status_incident_id) and
                 org_id == ^actor(:org_id) and project_id == ^actor(:project_id)
             )

      get? true
    end

    read :for_page do
      argument :status_page_id, :string, allow_nil?: false

      filter expr(
               status_page_id == ^arg(:status_page_id) and
                 org_id == ^actor(:org_id) and project_id == ^actor(:project_id)
             )

      pagination keyset?: true, required?: false
    end

    read :for_monitor do
      argument :status_page_id, :string, allow_nil?: false
      argument :monitor_id, :string, allow_nil?: false

      filter expr(
               status_page_id == ^arg(:status_page_id) and monitor_id == ^arg(:monitor_id) and
                 org_id == ^actor(:org_id) and project_id == ^actor(:project_id)
             )

      get? true
    end

    create :create do
      primary? true

      accept [
        :org_id,
        :project_id,
        :status_page_id,
        :monitor_id,
        :status_incident_id,
        :title,
        :body,
        :next_update_at,
        :suggested_service_ids,
        :service_states
      ]

      change {Alplus.Audit.Change,
              action: "status_incident_draft.create",
              subject_type: "status_incident_draft",
              project_id_attribute: :project_id}
    end

    update :update do
      primary? true
      accept [:title, :body, :next_update_at, :suggested_service_ids, :service_states]
      require_atomic? false

      change {Alplus.Audit.Change,
              action: "status_incident_draft.update",
              subject_type: "status_incident_draft",
              project_id_attribute: :project_id}
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
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
      constraints prefix: "sid"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:status_incident_draft) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :project_id, Alplus.Id,
      constraints: [prefix: "project"],
      allow_nil?: false,
      public?: true

    attribute :status_page_id, Alplus.Id,
      constraints: [prefix: "sp"],
      allow_nil?: false,
      public?: true

    attribute :monitor_id, Alplus.Id,
      constraints: [prefix: "mon"],
      allow_nil?: true,
      public?: true

    attribute :status_incident_id, Alplus.Id,
      constraints: [prefix: "sinc"],
      allow_nil?: true,
      public?: true

    attribute :title, :string,
      allow_nil?: false,
      default: "Service disruption",
      public?: true,
      constraints: [min_length: 1, max_length: 200]

    attribute :body, :string,
      allow_nil?: false,
      default: "We are investigating the issue.",
      public?: true,
      constraints: [min_length: 1, max_length: 32_768]

    attribute :next_update_at, :utc_datetime_usec, allow_nil?: true, public?: true

    attribute :suggested_service_ids, {:array, :string},
      allow_nil?: false,
      default: [],
      public?: true

    attribute :service_states, :map,
      allow_nil?: false,
      default: %{},
      public?: true

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

    belongs_to :status_page, Alplus.Status.StatusPage,
      source_attribute: :status_page_id,
      define_attribute?: false,
      allow_nil?: false

    belongs_to :monitor, Alplus.Monitoring.Monitor,
      source_attribute: :monitor_id,
      define_attribute?: false,
      allow_nil?: true

    belongs_to :status_incident, Alplus.Status.StatusIncident,
      source_attribute: :status_incident_id,
      define_attribute?: false,
      allow_nil?: true
  end
end
