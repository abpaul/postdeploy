defmodule Alplus.Seo.Profile do
  @moduledoc "One market-specific SEO profile for one Measure site."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Seo,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "seo_profiles"
    repo Alplus.Repo

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :source, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    read :for_source do
      get? true
      argument :source_id, :string, allow_nil?: false

      filter expr(
               org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                 source_id == ^arg(:source_id)
             )
    end

    read :list_for_project do
      argument :project_id, :string, allow_nil?: false
      filter expr(org_id == ^actor(:org_id) and project_id == ^arg(:project_id))
    end

    create :create do
      primary? true
      accept [:org_id, :project_id, :source_id, :target, :location_code, :language_code]
      validate Alplus.Seo.Profile.Validations.MeasureSourceInScope
    end

    update :update do
      accept [:target, :location_code, :language_code]
    end
  end

  policies do
    policy action([:read, :for_source, :list_for_project]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
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
      constraints prefix: "seop"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:seo_profile) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :project_id, Alplus.Id,
      constraints: [prefix: "project"],
      allow_nil?: false,
      public?: true

    attribute :source_id, Alplus.Id,
      constraints: [prefix: "source"],
      allow_nil?: false,
      public?: true

    attribute :target, :string, allow_nil?: false, public?: true, constraints: [max_length: 255]
    attribute :location_code, :integer, allow_nil?: false, public?: true, constraints: [min: 1]

    attribute :language_code, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: 8]

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

    belongs_to :source, Alplus.Sources.Source,
      source_attribute: :source_id,
      define_attribute?: false,
      allow_nil?: false
  end

  identities do
    identity :unique_source, [:source_id]
  end
end
