defmodule Alplus.Status.StatusIncident do
  @moduledoc "A customer-facing incident with an operator-controlled lifecycle."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Status,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "status_incidents"
    repo Alplus.Repo

    custom_statements do
      statement :status_incident_constraints do
        up """
        ALTER TABLE status_incidents
          ADD CONSTRAINT status_incidents_title_check CHECK (octet_length(btrim(title)) BETWEEN 1 AND 200),
          ADD CONSTRAINT status_incidents_body_check CHECK (octet_length(body) BETWEEN 1 AND 32768),
          ADD CONSTRAINT status_incidents_status_check CHECK (status IN ('open', 'closed'))
        """

        down """
        ALTER TABLE status_incidents
          DROP CONSTRAINT status_incidents_title_check,
          DROP CONSTRAINT status_incidents_body_check,
          DROP CONSTRAINT status_incidents_status_check
        """
      end
    end

    custom_indexes do
      index [:status_page_id, :published_at]
      index [:org_id, :project_id, :status]
    end

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :status_page, on_delete: :delete
      reference :incident, on_delete: :nilify
      reference :closed_by, on_delete: :nilify
    end
  end

  actions do
    defaults [:read]

    read :for_page do
      argument :status_page_id, :string, allow_nil?: false

      filter expr(
               status_page_id == ^arg(:status_page_id) and org_id == ^actor(:org_id) and
                 project_id == ^actor(:project_id) and not is_nil(published_at)
             )

      pagination keyset?: true, required?: false
    end

    read :operator_for_page do
      argument :status_page_id, :string, allow_nil?: false

      filter expr(
               status_page_id == ^arg(:status_page_id) and org_id == ^actor(:org_id) and
                 project_id == ^actor(:project_id)
             )

      pagination keyset?: true, required?: false
    end

    read :for_id do
      argument :incident_id, :string, allow_nil?: false

      filter expr(
               id == ^arg(:incident_id) and org_id == ^actor(:org_id) and
                 project_id == ^actor(:project_id) and not is_nil(published_at)
             )

      get? true
    end

    read :operator_for_id do
      argument :incident_id, :string, allow_nil?: false

      filter expr(
               id == ^arg(:incident_id) and org_id == ^actor(:org_id) and
                 project_id == ^actor(:project_id)
             )

      get? true
    end

    read :public_for_page do
      argument :status_page_id, :string, allow_nil?: false

      filter expr(
               status_page_id == ^arg(:status_page_id) and org_id == ^actor(:org_id) and
                 project_id == ^actor(:project_id) and not is_nil(published_at)
             )

      pagination keyset?: true, required?: false
    end

    create :publish do
      primary? true

      accept [
        :org_id,
        :project_id,
        :status_page_id,
        :incident_id,
        :title,
        :body,
        :stage,
        :next_update_at
      ]

      change set_attribute(:published_at, &DateTime.utc_now/0)
      change set_attribute(:is_private, false)
      change {Alplus.Status.Changes.PageInScope, page_id_attribute: :status_page_id}
      validate Alplus.Status.Validations.IncidentInScope

      change {Alplus.Audit.Change,
              action: "status_incident.publish",
              subject_type: "status_incident",
              project_id_attribute: :project_id}
    end

    create :draft do
      accept [
        :org_id,
        :project_id,
        :status_page_id,
        :incident_id,
        :title,
        :body,
        :stage,
        :next_update_at
      ]

      change set_attribute(:published_at, nil)
      change set_attribute(:is_private, true)
      change {Alplus.Status.Changes.PageInScope, page_id_attribute: :status_page_id}
      validate Alplus.Status.Validations.IncidentInScope

      change {Alplus.Audit.Change,
              action: "status_incident.draft",
              subject_type: "status_incident",
              project_id_attribute: :project_id}
    end

    update :update_content do
      primary? true
      accept [:title, :body, :stage, :next_update_at]
      require_atomic? false
      validate Alplus.Status.Validations.IncidentInScope

      change {Alplus.Audit.Change,
              action: "status_incident.update",
              subject_type: "status_incident",
              project_id_attribute: :project_id}
    end

    update :resolve do
      accept []
      require_atomic? false
      validate attribute_equals(:status, "open")
      change set_attribute(:status, "closed")
      change set_attribute(:stage, "resolved")
      change set_attribute(:next_update_at, nil)
      change set_attribute(:is_private, false)
      change set_attribute(:closed_at, &DateTime.utc_now/0)
      change relate_actor(:closed_by, field: :user_id, allow_nil?: false)

      change {Alplus.Audit.Change,
              action: "status_incident.resolve",
              subject_type: "status_incident",
              project_id_attribute: :project_id}
    end

    update :auto_recovery do
      accept []
      require_atomic? false
      change set_attribute(:recovery_posted_at, &DateTime.utc_now/0)
    end

    update :publish_draft do
      accept [:title, :body, :stage, :next_update_at]
      require_atomic? false
      validate attribute_equals(:is_private, true)
      change set_attribute(:published_at, &DateTime.utc_now/0)
      change set_attribute(:is_private, false)

      change {Alplus.Audit.Change,
              action: "status_incident.publish_draft",
              subject_type: "status_incident",
              project_id_attribute: :project_id}
    end
  end

  policies do
    policy action(:public_for_page) do
      authorize_if expr(
                     status_page_id == ^actor(:status_page_id) and
                       org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       not is_nil(published_at) and
                       exists(status_page, exists(public_page, not is_nil(published_at)))
                   )
    end

    policy action([:read, :for_page, :for_id]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action([:operator_for_page, :operator_for_id]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:user_id) and role in ["owner", "admin"]
                       )
                   )
    end

    policy action_type([:create, :update]) do
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
      constraints prefix: "sinc"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:status_incident) end
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

    attribute :incident_id, Alplus.Id,
      constraints: [prefix: "inc"],
      allow_nil?: true,
      public?: true

    attribute :title, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 200]

    attribute :body, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 32_768]

    attribute :status, :string, allow_nil?: false, default: "open", public?: true

    attribute :stage, :string,
      allow_nil?: false,
      default: "investigating",
      public?: true

    attribute :next_update_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :published_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :closed_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :recovery_posted_at, :utc_datetime_usec, allow_nil?: true, public?: false
    attribute :is_private, :boolean, allow_nil?: false, default: false, public?: false

    attribute :closed_by_id, Alplus.Id,
      constraints: [prefix: "user"],
      allow_nil?: true,
      writable?: false,
      public?: false

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

    belongs_to :incident, Alplus.Monitoring.Incident,
      source_attribute: :incident_id,
      define_attribute?: false,
      allow_nil?: true

    belongs_to :closed_by, Alplus.Accounts.User,
      source_attribute: :closed_by_id,
      define_attribute?: false,
      allow_nil?: true

    has_many :updates, Alplus.Status.StatusIncidentUpdate,
      destination_attribute: :status_incident_id
  end
end
