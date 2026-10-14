defmodule Alplus.Status.StatusComponent do
  @moduledoc "A customer-facing group of Monitor checks on a status page."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Status,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "status_components"
    repo Alplus.Repo

    custom_statements do
      statement :status_component_constraints do
        up """
        ALTER TABLE status_components
          ADD CONSTRAINT status_components_name_check CHECK (octet_length(btrim(name)) BETWEEN 1 AND 200),
          ADD CONSTRAINT status_components_position_check CHECK (position >= 0)
        """

        down """
        ALTER TABLE status_components
          DROP CONSTRAINT status_components_name_check,
          DROP CONSTRAINT status_components_position_check
        """
      end

      # One service name per status page, insensitive to case and to surrounding
      # whitespace. `Alplus.Status.API.create_service/2` reports the clash to the
      # operator before it writes; this index is the backstop against two
      # concurrent creates racing past that check.
      statement :status_component_name_unique do
        up """
        CREATE UNIQUE INDEX status_components_page_name_index
          ON status_components (status_page_id, lower(btrim(name)))
        """

        down """
        DROP INDEX status_components_page_name_index
        """
      end
    end

    custom_indexes do
      index [:status_page_id, :position]
      index [:org_id, :project_id]
    end

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :status_page, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    read :for_page do
      argument :status_page_id, :string, allow_nil?: false

      filter expr(
               status_page_id == ^arg(:status_page_id) and org_id == ^actor(:org_id) and
                 project_id == ^actor(:project_id)
             )

      pagination keyset?: true, required?: false
    end

    read :public_for_page do
      argument :status_page_id, :string, allow_nil?: false

      filter expr(
               status_page_id == ^arg(:status_page_id) and org_id == ^actor(:org_id) and
                 project_id == ^actor(:project_id)
             )

      pagination keyset?: true, required?: false
    end

    create :create do
      primary? true
      accept [:org_id, :project_id, :status_page_id, :name, :description, :position]
      change {Alplus.Status.Changes.PageInScope, page_id_attribute: :status_page_id}
    end

    update :update do
      primary? true
      accept [:name, :description, :position]
      require_atomic? false
    end

    destroy :destroy do
      primary? true
    end
  end

  policies do
    policy action(:public_for_page) do
      authorize_if expr(
                     status_page_id == ^actor(:status_page_id) and
                       org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(status_page, exists(public_page, not is_nil(published_at)))
                   )
    end

    policy action([:read, :for_page]) do
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
      constraints prefix: "scomp"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:status_component) end
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

    attribute :name, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 200]

    attribute :description, :string,
      allow_nil?: true,
      public?: true,
      constraints: [max_length: 500]

    attribute :position, :integer, allow_nil?: false, default: 0, public?: true
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
  end
end
