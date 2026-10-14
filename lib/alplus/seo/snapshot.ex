defmodule Alplus.Seo.Snapshot do
  @moduledoc "One successful SEO result set retained for dashboard reads."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Seo,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "seo_snapshots"
    repo Alplus.Repo

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :profile, on_delete: :delete
      reference :refresh, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    read :latest_for_profile do
      get? true
      argument :profile_id, :string, allow_nil?: false

      filter expr(
               org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                 profile_id == ^arg(:profile_id)
             )

      prepare build(sort: [captured_at: :desc])
    end

    create :create do
      primary? true

      accept [
        :org_id,
        :project_id,
        :profile_id,
        :refresh_id,
        :captured_at,
        :overview,
        :keywords,
        :pages,
        :competitors
      ]
    end
  end

  policies do
    policy always() do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end
  end

  attributes do
    attribute :id, Alplus.Id,
      constraints: [prefix: "seos"],
      primary_key?: true,
      allow_nil?: false,
      writable?: false,
      default: fn -> Alplus.Id.generate(:seo_snapshot) end

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

    attribute :refresh_id, Alplus.Id,
      constraints: [prefix: "seor"],
      allow_nil?: false,
      public?: true

    attribute :captured_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :overview, :map, allow_nil?: false, default: %{}, public?: true
    attribute :keywords, {:array, :map}, allow_nil?: false, default: [], public?: true
    attribute :pages, {:array, :map}, allow_nil?: false, default: [], public?: true
    attribute :competitors, {:array, :map}, allow_nil?: false, default: [], public?: true
    create_timestamp :inserted_at
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

    belongs_to :refresh, Alplus.Seo.Refresh,
      source_attribute: :refresh_id,
      define_attribute?: false,
      allow_nil?: false
  end
end
