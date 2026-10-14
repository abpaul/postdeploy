defmodule Alplus.Seo.Competitor do
  @moduledoc "A manually selected competitor for one SEO profile."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Seo,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "seo_competitors"
    repo Alplus.Repo

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :profile, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    read :list_for_profile do
      argument :profile_id, :string, allow_nil?: false

      filter expr(
               org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                 profile_id == ^arg(:profile_id)
             )
    end

    create :create do
      primary? true
      accept [:org_id, :project_id, :profile_id, :target]
      validate Alplus.Seo.Competitor.Validations.ProfileInScope
    end

    destroy :destroy do
      primary? true
    end
  end

  policies do
    policy action([:read, :list_for_profile]) do
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
      constraints prefix: "seoc"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:seo_competitor) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :project_id, Alplus.Id,
      constraints: [prefix: "project"],
      allow_nil?: false,
      public?: true

    attribute :profile_id, Alplus.Id,
      constraints: [prefix: "seop"],
      allow_nil?: false,
      public?: true

    attribute :target, :string, allow_nil?: false, public?: true, constraints: [max_length: 255]

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

    belongs_to :profile, Alplus.Seo.Profile,
      source_attribute: :profile_id,
      define_attribute?: false,
      allow_nil?: false
  end

  identities do
    identity :unique_target_per_profile, [:profile_id, :target]
  end
end
