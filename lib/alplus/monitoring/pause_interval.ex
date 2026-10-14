defmodule Alplus.Monitoring.PauseInterval do
  @moduledoc false

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Monitoring,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "monitor_pause_intervals"
    repo Alplus.Repo

    custom_indexes do
      index [:monitor_id],
        unique: true,
        where: "resumed_at IS NULL",
        name: "monitor_pause_intervals_one_open_index"

      index [:org_id, :project_id, :monitor_id, :paused_at]
    end

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :monitor, on_delete: :delete
    end
  end

  actions do
    defaults [:read]
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "mpau"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:monitor_pause_interval) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :project_id, Alplus.Id,
      constraints: [prefix: "project"],
      allow_nil?: false,
      public?: true

    attribute :monitor_id, Alplus.Id,
      constraints: [prefix: "mon"],
      allow_nil?: false,
      public?: true

    attribute :paused_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :resumed_at, :utc_datetime_usec, allow_nil?: true, public?: true
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

    belongs_to :monitor, Alplus.Monitoring.Monitor,
      source_attribute: :monitor_id,
      define_attribute?: false,
      allow_nil?: false
  end
end
