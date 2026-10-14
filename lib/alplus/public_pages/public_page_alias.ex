defmodule Alplus.PublicPages.PublicPageAlias do
  @moduledoc "A reserved legacy URL for one project's public page."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.PublicPages,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "public_page_aliases"
    repo Alplus.Repo

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :public_page, on_delete: :delete
    end

    custom_indexes do
      index [:public_slug], unique: true, name: "public_page_aliases_slug_unique_index"
      index [:org_id, :project_id], name: "public_page_aliases_org_project_index"
    end
  end

  actions do
    create :create do
      primary? true
      accept [:id, :org_id, :project_id, :public_page_id, :public_slug, :kind, :source_id]
    end

    read :public_by_slug do
      get? true
      argument :slug, :string, allow_nil?: false
      filter expr(public_slug == ^arg(:slug))
    end

    read :by_slug_internal do
      argument :slug, :string, allow_nil?: false
      filter expr(public_slug == ^arg(:slug))
    end

    read :public_by_kind do
      get? true
      argument :slug, :string, allow_nil?: false
      argument :kind, :string, allow_nil?: false
      filter expr(public_slug == ^arg(:slug) and kind == ^arg(:kind))
    end

    read :for_project do
      argument :project_id, :string, allow_nil?: false
      filter expr(project_id == ^arg(:project_id))
    end
  end

  policies do
    policy action_type(:create) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:user_id) and role in ["owner", "admin"]
                       )
                   )
    end

    policy action(:public_by_slug) do
      authorize_if expr(public_slug == ^actor(:slug))
    end

    policy action(:public_by_kind) do
      authorize_if expr(public_slug == ^actor(:slug) and kind == ^actor(:kind))
    end

    policy action(:for_project) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      # Legacy aliases use deterministic ids during consolidation. Runtime
      # slug changes use the same deterministic id so retries stay idempotent.
      writable? true
      public? true
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

    attribute :public_page_id, Alplus.Id do
      constraints prefix: "ppage"
      allow_nil? false
      public? true
    end

    attribute :public_slug, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 100
    end

    attribute :kind, :string do
      allow_nil? false
      public? true
      default "status"
      constraints max_length: 32, match: ~r/\A(?:status|changelog)\z/
    end

    attribute :source_id, :string do
      allow_nil? true
      public? false
    end

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

    belongs_to :public_page, Alplus.PublicPages.PublicPage,
      source_attribute: :public_page_id,
      define_attribute?: false,
      allow_nil?: false
  end
end
