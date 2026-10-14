defmodule Alplus.Changelog.Changelog do
  @moduledoc "A project's changelog content. Public identity lives in PublicPages."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Changelog,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "changelogs"
    repo Alplus.Repo

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
    end

    custom_indexes do
      index [:project_id], unique: true, name: "changelogs_one_per_project_index"

      index [:vendor?],
        unique: true,
        name: "changelogs_one_vendor_index",
        where: ~s|("vendor?" = true)|
    end
  end

  actions do
    defaults [:read]

    read :for_project do
      argument :project_id, :string, allow_nil?: false
      filter expr(project_id == ^arg(:project_id))
    end

    read :public_by_slug do
      argument :slug, :string, allow_nil?: false
      filter expr(project_id == ^actor(:project_id))
    end

    read :public_by_project do
      argument :project_id, :string, allow_nil?: false

      filter expr(project_id == ^arg(:project_id))
    end

    read :read_public do
      get? true

      filter expr(
               id == ^actor(:changelog_id) and
                 org_id == ^actor(:org_id) and
                 project_id == ^actor(:project_id)
             )
    end

    read :read_vendor do
      get? true
      filter expr(vendor? == true)
    end

    create :create do
      primary? true
      accept [:org_id, :project_id]
      change Alplus.Changelog.Changes.EnforcePlan
    end

    update :designate_vendor do
      require_atomic? false
      accept []

      change Alplus.Changelog.Changes.EnforcePlan

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :vendor?, true)
      end
    end

    create :bootstrap do
      accept [:org_id, :project_id]
      change Alplus.Changelog.Changes.EnforcePlan
    end

    update :update do
      primary? true
      require_atomic? false
      accept []
      change Alplus.Changelog.Changes.EnforcePlan
    end

    destroy :destroy do
      primary? true
      require_atomic? false
      change Alplus.Changelog.Changes.EnforcePlan
    end
  end

  policies do
    policy action([:read, :for_project]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action(:create) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:user_id) and role in ["owner", "admin"]
                       )
                   )
    end

    policy action(:bootstrap) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action([:update, :destroy]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:user_id) and role in ["owner", "admin"]
                       )
                   )
    end

    policy action(:activate) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action(:read_public) do
      authorize_if expr(
                     id == ^actor(:changelog_id) and
                       org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id)
                   )
    end

    policy action(:public_by_slug) do
      authorize_if expr(project_id == ^actor(:project_id))
    end

    policy action(:public_by_project) do
      authorize_if expr(project_id == ^actor(:project_id))
    end

    policy action(:read_vendor) do
      authorize_if expr(vendor? == true)
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "clog"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:changelog) end
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

    attribute :vendor?, :boolean,
      allow_nil?: false,
      default: false,
      writable?: false,
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

    has_many :entries, Alplus.Changelog.Entry, destination_attribute: :changelog_id

    has_many :activity_events, Alplus.Changelog.ActivityEvent,
      destination_attribute: :changelog_id

    has_one :public_page, Alplus.PublicPages.PublicPage,
      source_attribute: :project_id,
      destination_attribute: :project_id
  end
end
