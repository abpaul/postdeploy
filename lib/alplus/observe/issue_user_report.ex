defmodule Alplus.Observe.IssueUserReport do
  @moduledoc """
  A user-feedback report attached to one Observe issue.

  Operators record what a user sent. The SDK does not ingest these yet.
  Scoped by org and project. A read failure filters the row (404), never 403.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Observe,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "issue_user_reports"
    repo Alplus.Repo

    custom_indexes do
      index [:org_id, :project_id, :issue_id, :inserted_at]
    end

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :issue, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    read :list_for_issue do
      argument :issue_id, :string, allow_nil?: false

      filter expr(
               org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                 issue_id == ^arg(:issue_id)
             )
    end

    create :create do
      primary? true
      accept [:org_id, :project_id, :issue_id, :name, :email, :comments, :event_id]
    end

    destroy :destroy do
      primary? true
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action_type([:create, :destroy]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:user_id) and role in ["owner", "admin"]
                       )
                   )
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "iur"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:issue_user_report) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :project_id, Alplus.Id,
      constraints: [prefix: "project"],
      allow_nil?: false,
      public?: true

    attribute :issue_id, Alplus.Id,
      constraints: [prefix: "iss"],
      allow_nil?: false,
      public?: true

    attribute :name, :string, allow_nil?: true, public?: true, constraints: [max_length: 256]
    attribute :email, :string, allow_nil?: true, public?: true, constraints: [max_length: 256]

    attribute :comments, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 4_096]

    attribute :event_id, :string, allow_nil?: true, public?: true, constraints: [max_length: 64]

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

    belongs_to :issue, Alplus.Observe.Issue,
      source_attribute: :issue_id,
      define_attribute?: false,
      allow_nil?: false
  end
end
