defmodule Alplus.Measure.AnalyticsDimension do
  @moduledoc "A bounded, privacy-safe daily Measure breakdown."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Measure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "analytics_dimensions"
    repo Alplus.Repo

    custom_indexes do
      # Partitioned per Measure Source (site), not just per project/environment
      # (issue #34, Model A): two sites can share a project and environment.
      index [:project_id, :environment, :date, :dimension, :value, :source_id], unique: true
      index [:org_id, :project_id, :date, :dimension, :visitors]
      index [:org_id, :source_id, :date, :dimension, :visitors]
    end

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :source, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    read :list_for_project do
      argument :project_id, :string, allow_nil?: false
      filter expr(org_id == ^actor(:org_id) and project_id == ^arg(:project_id))
    end

    # One site's own dimension breakdowns (issue #34, Model A): scoped by
    # source_id, not merely project_id, so a sibling site sharing the same
    # project (and possibly the same environment) never bleeds into this
    # read.
    read :list_for_source do
      argument :source_id, :string, allow_nil?: false
      argument :since, :date, allow_nil?: false
      argument :until, :date, allow_nil?: false
      argument :environment, :string, allow_nil?: false

      filter expr(
               org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                 source_id == ^arg(:source_id) and environment == ^arg(:environment) and
                 date >= ^arg(:since) and date <= ^arg(:until)
             )
    end

    read :list_for_share do
      argument :dimension, :string, allow_nil?: false
      argument :since, :date, allow_nil?: false
      argument :until, :date, allow_nil?: false

      filter expr(
               org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                 source_id == ^actor(:source_id) and dimension == ^arg(:dimension) and
                 date >= ^arg(:since) and date <= ^arg(:until)
             )
    end
  end

  policies do
    policy action([:read, :list_for_project, :list_for_source]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action(:list_for_share) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       source_id == ^actor(:source_id)
                   )
    end
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true

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

    attribute :environment, :string, allow_nil?: false, public?: true
    attribute :date, :date, allow_nil?: false, public?: true
    attribute :dimension, :string, allow_nil?: false, public?: true
    attribute :value, :string, allow_nil?: false, public?: true
    attribute :visitors, :integer, allow_nil?: false, default: 0, public?: true
    attribute :pageviews, :integer, allow_nil?: false, default: 0, public?: true
    attribute :visits, :integer, public?: true
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
end
