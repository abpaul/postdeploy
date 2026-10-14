defmodule Alplus.Status.StatusIncidentUpdate do
  @moduledoc "An update in a published status incident timeline."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Status,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "status_incident_updates"
    repo Alplus.Repo

    custom_statements do
      statement :status_incident_update_constraints do
        up "ALTER TABLE status_incident_updates ADD CONSTRAINT status_incident_updates_body_check CHECK (octet_length(body) BETWEEN 1 AND 32768)"

        down "ALTER TABLE status_incident_updates DROP CONSTRAINT status_incident_updates_body_check"
      end
    end

    custom_indexes do
      index [:status_incident_id, :inserted_at]
      index [:org_id, :project_id]
    end

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :status_incident, on_delete: :delete
      reference :actor, on_delete: :nilify
    end
  end

  actions do
    defaults [:read]

    read :public_for_incident do
      argument :status_incident_id, :string, allow_nil?: false

      filter expr(
               status_incident_id == ^arg(:status_incident_id) and org_id == ^actor(:org_id) and
                 project_id == ^actor(:project_id)
             )

      pagination keyset?: true, required?: false
    end

    read :public_for_incidents do
      argument :status_incident_ids, {:array, :string}, allow_nil?: false

      filter expr(
               status_incident_id in ^arg(:status_incident_ids) and
                 org_id == ^actor(:org_id) and project_id == ^actor(:project_id)
             )
    end

    create :publish do
      primary? true
      accept [:org_id, :project_id, :status_incident_id, :body]
      change set_attribute(:kind, "note")

      change {Alplus.Audit.Change,
              action: "status_incident.update",
              subject_type: "status_incident_update",
              project_id_attribute: :project_id}

      change relate_actor(:actor, field: :user_id, allow_nil?: false)
    end

    create :recovery do
      accept [:org_id, :project_id, :status_incident_id, :body]
      change set_attribute(:kind, "recovery")
    end
  end

  policies do
    policy action([:public_for_incident, :public_for_incidents]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(
                         status_incident,
                         status_page_id == ^actor(:status_page_id) and
                           not is_nil(published_at)
                       )
                   )
    end

    policy action([:read]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action(:publish) do
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
      constraints prefix: "siup"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:status_incident_update) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :project_id, Alplus.Id,
      constraints: [prefix: "project"],
      allow_nil?: false,
      public?: true

    attribute :status_incident_id, Alplus.Id,
      constraints: [prefix: "sinc"],
      allow_nil?: false,
      public?: true

    attribute :body, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 32_768]

    attribute :kind, :string, allow_nil?: false, default: "note", public?: true

    attribute :actor_id, Alplus.Id,
      constraints: [prefix: "user"],
      allow_nil?: true,
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

    belongs_to :status_incident, Alplus.Status.StatusIncident,
      source_attribute: :status_incident_id,
      define_attribute?: false,
      allow_nil?: false

    belongs_to :actor, Alplus.Accounts.User,
      source_attribute: :actor_id,
      define_attribute?: false,
      allow_nil?: true
  end
end
