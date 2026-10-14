defmodule Alplus.Measure.AnalyticsDay do
  @moduledoc "One project/environment day of privacy-safe Measure aggregates."

  # PublicEvidence bounds five production sources over thirty days (150 rows).
  # The public read must cover the complete longest homepage range.
  @public_homepage_cap 150

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Measure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "analytics_days"
    repo Alplus.Repo

    custom_indexes do
      # Partitioned per Measure Source (site), not just per project/environment
      # (issue #34, Model A): two sites can share a project and environment.
      index [:project_id, :environment, :date, :source_id], unique: true
      index [:org_id, :project_id, :date]
      index [:org_id, :source_id, :date]
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

    read :list_for_projects do
      argument :project_ids, {:array, :string}, allow_nil?: false
      argument :source_ids, {:array, :string}, allow_nil?: false
      argument :since, :date, allow_nil?: false
      argument :until, :date, allow_nil?: false

      filter expr(
               org_id == ^actor(:org_id) and project_id in ^arg(:project_ids) and
                 source_id in ^arg(:source_ids) and date >= ^arg(:since) and date < ^arg(:until)
             )
    end

    # One site's own day rollups (issue #34, Model A): scoped by source_id,
    # not merely project_id, so a sibling site sharing the same project (and
    # possibly the same environment) never bleeds into this read.
    read :list_for_source do
      argument :source_id, :string, allow_nil?: false
      argument :since, :date, allow_nil?: false

      filter expr(
               org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                 source_id == ^arg(:source_id) and date >= ^arg(:since)
             )
    end

    # The card-grid batch read: every site's day rollups for a window in one
    # query, so rendering N cards never runs N per-card queries.
    read :list_for_sources do
      argument :source_ids, {:array, :string}, allow_nil?: false
      argument :since, :date, allow_nil?: false
      argument :until, :date, allow_nil?: false

      filter expr(
               org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                 source_id in ^arg(:source_ids) and date >= ^arg(:since) and date < ^arg(:until)
             )
    end

    read :list_for_share do
      argument :since, :date, allow_nil?: false
      argument :until, :date, allow_nil?: false

      filter expr(
               org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                 source_id == ^actor(:source_id) and environment == ^actor(:environment) and
                 date >= ^arg(:since) and
                 date < ^arg(:until)
             )
    end

    read :public_homepage_for_vendor do
      argument :source_ids, {:array, :string}, allow_nil?: false
      argument :since, :date, allow_nil?: false
      argument :until, :date, allow_nil?: false

      filter expr(
               org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                 source_id in ^arg(:source_ids) and environment == "production" and
                 date >= ^arg(:since) and date < ^arg(:until)
             )

      prepare build(
                select: [:source_id, :date, :pageviews, :visitors],
                sort: [date: :asc, id: :asc],
                limit: @public_homepage_cap
              )
    end

    read :exists_for_projects do
      argument :project_ids, {:array, :string}, allow_nil?: false
      filter expr(org_id == ^actor(:org_id) and project_id in ^arg(:project_ids))
    end
  end

  policies do
    policy action([:read, :list_for_project, :list_for_source, :list_for_sources]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action([:list_for_projects, :exists_for_projects]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action(:list_for_share) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       source_id == ^actor(:source_id) and environment == ^actor(:environment)
                   )
    end

    policy action(:public_homepage_for_vendor) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       environment == "production"
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
    attribute :pageviews, :integer, allow_nil?: false, default: 0, public?: true
    attribute :visitors, :integer, allow_nil?: false, default: 0, public?: true
    attribute :visits, :integer, allow_nil?: false, default: 0, public?: true
    attribute :bounces, :integer, allow_nil?: false, default: 0, public?: true
    attribute :duration_seconds, :integer, allow_nil?: false, default: 0, public?: true
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
