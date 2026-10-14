defmodule Alplus.Measure.GoalConversion do
  @moduledoc "An hourly, privacy-safe conversion count for a configured Measure goal."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Measure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "goal_conversions"
    repo Alplus.Repo

    custom_indexes do
      index [:goal_id, :environment, :hour], unique: true
      index [:org_id, :project_id, :hour]
    end

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :goal, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    read :list_for_project do
      argument :project_id, :string, allow_nil?: false
      filter expr(org_id == ^actor(:org_id) and project_id == ^arg(:project_id))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
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

    attribute :goal_id, Alplus.Id, constraints: [prefix: "goal"], allow_nil?: false, public?: true
    attribute :environment, :string, allow_nil?: false, public?: true
    attribute :hour, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :conversions, :integer, allow_nil?: false, default: 0, public?: true
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

    belongs_to :goal, Alplus.Measure.Goal,
      source_attribute: :goal_id,
      define_attribute?: false,
      allow_nil?: false
  end
end
