defmodule Alplus.PublicPages.PublicPage do
  @moduledoc "The shared public identity for one project."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.PublicPages,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "public_pages"
    repo Alplus.Repo

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
    end

    custom_indexes do
      index [:project_id], unique: true, name: "public_pages_project_unique_index"
      index [:public_slug], unique: true, name: "public_pages_slug_unique_index"
      index [:org_id, :project_id], name: "public_pages_org_project_index"
    end
  end

  actions do
    defaults [:read]

    read :for_project do
      get? true
      argument :org_id, :string, allow_nil?: false
      argument :project_id, :string, allow_nil?: false
      filter expr(org_id == ^arg(:org_id) and project_id == ^arg(:project_id))
    end

    read :public_by_slug do
      get? true
      argument :slug, :string, allow_nil?: false
      filter expr(public_slug == ^arg(:slug) and not is_nil(published_at))
    end

    read :public_by_project do
      get? true
      argument :project_id, :string, allow_nil?: false
      filter expr(project_id == ^arg(:project_id) and not is_nil(published_at))
    end

    read :read_public do
      get? true

      filter expr(
               id == ^actor(:public_page_id) and org_id == ^actor(:org_id) and
                 project_id == ^actor(:project_id) and not is_nil(published_at)
             )
    end

    create :create do
      primary? true
      accept [:org_id, :project_id, :public_slug, :title, :logo_url]
      validate Alplus.PublicPages.Validations.Slug
      validate Alplus.PublicPages.Validations.LogoUrl

      change {Alplus.Audit.Change,
              action: "public_page.create",
              subject_type: "public_page",
              project_id_attribute: :project_id}
    end

    create :create_internal do
      accept [:org_id, :project_id, :public_slug, :title, :logo_url]
      validate Alplus.PublicPages.Validations.Slug
      validate Alplus.PublicPages.Validations.LogoUrl
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:public_slug, :title, :logo_url]
      validate Alplus.PublicPages.Validations.Slug
      validate Alplus.PublicPages.Validations.LogoUrl

      change {Alplus.Audit.Change,
              action: "public_page.update",
              subject_type: "public_page",
              project_id_attribute: :project_id}
    end

    update :update_internal do
      require_atomic? false
      accept [:public_slug, :title, :logo_url]
      validate Alplus.PublicPages.Validations.Slug
      validate Alplus.PublicPages.Validations.LogoUrl
    end

    update :publish do
      require_atomic? false
      accept []
      change set_attribute(:published_at, &DateTime.utc_now/0)

      change {Alplus.Audit.Change,
              action: "public_page.publish",
              subject_type: "public_page",
              project_id_attribute: :project_id}
    end

    update :unpublish do
      require_atomic? false
      accept []
      change set_attribute(:published_at, nil)

      change {Alplus.Audit.Change,
              action: "public_page.unpublish",
              subject_type: "public_page",
              project_id_attribute: :project_id}
    end
  end

  policies do
    policy action([:read, :for_project]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action([:create, :create_internal]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:user_id) and role in ["owner", "admin"]
                       )
                   )
    end

    policy action([:update, :publish, :unpublish]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:user_id) and role in ["owner", "admin"]
                       )
                   )
    end

    policy action(:update_internal) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:user_id) and role in ["owner", "admin"]
                       )
                   )
    end

    policy action(:public_by_slug) do
      authorize_if expr(public_slug == ^actor(:slug) and not is_nil(published_at))
    end

    policy action(:public_by_project) do
      authorize_if expr(project_id == ^actor(:project_id) and not is_nil(published_at))
    end

    policy action(:read_public) do
      authorize_if expr(
                     id == ^actor(:public_page_id) and org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and not is_nil(published_at)
                   )
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "ppage"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:public_page) end
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

    attribute :public_slug, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 100, match: ~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/
    end

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 200
    end

    attribute :logo_url, :string do
      allow_nil? true
      public? true
      constraints max_length: 2048
    end

    attribute :published_at, :utc_datetime_usec,
      allow_nil?: true,
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
  end

  identities do
    identity :one_per_project, [:project_id]
    identity :unique_public_slug, [:public_slug]
  end
end
