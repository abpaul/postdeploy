defmodule Alplus.Measure.Goal do
  @moduledoc "A project conversion rule evaluated once for each Measure visit."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Measure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "goals"
    repo Alplus.Repo

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    read :list_for_project do
      argument :project_id, :string, allow_nil?: false
      filter expr(org_id == ^actor(:org_id) and project_id == ^arg(:project_id))
    end

    create :create do
      primary? true
      accept [:org_id, :project_id, :name, :kind, :path, :event_name]
      validate Alplus.Measure.Validations.GoalShape

      change {Alplus.Measure.Changes.EnforceGoalCapacity, []}

      change {Alplus.Audit.Change,
              action: "goal.create", subject_type: "goal", project_id_attribute: :project_id}
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:name, :kind, :path, :event_name]
      validate Alplus.Measure.Validations.GoalShape

      # Entitlement gate: an inactive organization (expired trial, lapsed
      # subscription) may not edit goals. Reads stay open.
      change fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn changeset ->
          case Alplus.Billing.Access.check(Ash.Changeset.get_attribute(changeset, :org_id)) do
            {:ok, _access} -> changeset
            {:error, %{message: message}} -> Ash.Changeset.add_error(changeset, message: message)
          end
        end)
      end

      change {Alplus.Audit.Change,
              action: "goal.update", subject_type: "goal", project_id_attribute: :project_id}
    end

    destroy :destroy do
      primary? true
      require_atomic? false

      change {Alplus.Audit.Change,
              action: "goal.destroy", subject_type: "goal", project_id_attribute: :project_id}
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action_type([:create, :update, :destroy]) do
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
      constraints prefix: "goal"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:goal) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :project_id, Alplus.Id,
      constraints: [prefix: "project"],
      allow_nil?: false,
      public?: true

    attribute :name, :string, allow_nil?: false, public?: true, constraints: [max_length: 120]
    attribute :kind, :string, allow_nil?: false, public?: true
    attribute :path, :string, public?: true, constraints: [max_length: 2048]

    attribute :event_name, :string,
      public?: true,
      constraints: [max_length: 64, match: ~r/^[a-z0-9_-]+$/]

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
  end
end
