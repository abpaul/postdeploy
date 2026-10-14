defmodule Alplus.Measure.CustomEventDefinition do
  @moduledoc "A named custom Measure event. Event properties are always discarded."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Measure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "custom_event_definitions"
    repo Alplus.Repo

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
    end

    create :create do
      primary? true
      accept [:org_id, :project_id, :name]

      change {Alplus.Audit.Change,
              action: "event_definition.create",
              subject_type: "measure_event_definition",
              project_id_attribute: :project_id}
    end

    destroy :destroy do
      primary? true
      require_atomic? false

      change {Alplus.Audit.Change,
              action: "event_definition.destroy",
              subject_type: "measure_event_definition",
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

    policy action_type([:create, :destroy]) do
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
      constraints prefix: "event"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:custom_event_definition) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :project_id, Alplus.Id,
      constraints: [prefix: "project"],
      allow_nil?: false,
      public?: true

    attribute :name, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: 64, match: ~r/^[a-z0-9_-]+$/]

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
  end

  identities do
    identity :unique_name_per_project, [:project_id, :name]
  end
end
