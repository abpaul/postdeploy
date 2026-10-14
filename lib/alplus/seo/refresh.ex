defmodule Alplus.Seo.Refresh do
  @moduledoc "One requested SEO collection, including its provider cost and terminal outcome."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Seo,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "seo_refreshes"
    repo Alplus.Repo

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :profile, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    create :queue do
      primary? true
      accept [:org_id, :project_id, :profile_id, :kind, :month, :reserved_cost_microusd]
    end

    update :start do
      accept []
      change set_attribute(:status, :running)
    end

    update :succeed do
      accept [:actual_cost_microusd]
      change set_attribute(:status, :succeeded)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
    end

    update :fail do
      accept [:failure_reason, :actual_cost_microusd]
      change set_attribute(:status, :failed)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
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
      constraints: [prefix: "seor"],
      primary_key?: true,
      allow_nil?: false,
      writable?: false,
      default: fn -> Alplus.Id.generate(:seo_refresh) end

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

    attribute :kind, :atom,
      constraints: [one_of: [:initial, :scheduled, :manual]],
      allow_nil?: false,
      public?: true

    attribute :status, :atom,
      constraints: [one_of: [:queued, :running, :succeeded, :failed]],
      allow_nil?: false,
      default: :queued,
      public?: true

    attribute :month, :date, allow_nil?: false, public?: true
    attribute :reserved_cost_microusd, :integer, allow_nil?: false, default: 0, public?: true
    attribute :actual_cost_microusd, :integer, allow_nil?: false, default: 0, public?: true
    attribute :failure_reason, :string, constraints: [max_length: 500], public?: true
    attribute :completed_at, :utc_datetime_usec, public?: true
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
end
