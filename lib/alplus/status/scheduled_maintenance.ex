defmodule Alplus.Status.ScheduledMaintenance do
  @moduledoc "A public maintenance window that pauses its member monitors."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Status,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "status_scheduled_maintenances"
    repo Alplus.Repo

    custom_statements do
      statement :scheduled_maintenance_constraints do
        up """
        ALTER TABLE status_scheduled_maintenances
          ADD CONSTRAINT status_maintenance_title_check CHECK (octet_length(btrim(title)) BETWEEN 1 AND 200),
          ADD CONSTRAINT status_maintenance_description_check CHECK (description IS NULL OR octet_length(description) <= 32768),
          ADD CONSTRAINT status_maintenance_status_check CHECK (status IN ('scheduled', 'active', 'completed', 'cancelled')),
          ADD CONSTRAINT status_maintenance_window_check CHECK (starts_at < ends_at)
        """

        down """
        ALTER TABLE status_scheduled_maintenances
          DROP CONSTRAINT status_maintenance_title_check,
          DROP CONSTRAINT status_maintenance_description_check,
          DROP CONSTRAINT status_maintenance_status_check,
          DROP CONSTRAINT status_maintenance_window_check
        """
      end
    end

    custom_indexes do
      index [:status_page_id, :starts_at]
      index [:org_id, :project_id, :status, :starts_at]
    end

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :status_page, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    read :for_page do
      argument :status_page_id, :string, allow_nil?: false

      filter expr(
               status_page_id == ^arg(:status_page_id) and org_id == ^actor(:org_id) and
                 project_id == ^actor(:project_id)
             )

      pagination keyset?: true, required?: false
    end

    read :public_for_page do
      argument :status_page_id, :string, allow_nil?: false

      filter expr(
               status_page_id == ^arg(:status_page_id) and org_id == ^actor(:org_id) and
                 project_id == ^actor(:project_id)
             )

      pagination keyset?: true, required?: false
    end

    read :public_history do
      argument :status_page_id, :string, allow_nil?: false

      filter expr(
               status_page_id == ^arg(:status_page_id) and org_id == ^actor(:org_id) and
                 project_id == ^actor(:project_id)
             )

      pagination keyset?: true, required?: false
    end

    create :schedule do
      primary? true
      accept [:org_id, :project_id, :status_page_id, :title, :description, :starts_at, :ends_at]
      validate Alplus.Status.Validations.Window
      change {Alplus.Status.Changes.PageInScope, page_id_attribute: :status_page_id}

      change {Alplus.Audit.Change,
              action: "maintenance.schedule",
              subject_type: "scheduled_maintenance",
              project_id_attribute: :project_id}
    end

    update :activate do
      accept []
      require_atomic? false
      validate attribute_equals(:status, "scheduled")
      change set_attribute(:status, "active")
    end

    update :complete do
      accept []
      require_atomic? false
      validate attribute_equals(:status, "active")
      change set_attribute(:status, "completed")
    end

    # An operator cancels a window that is still scheduled, or ends one that is
    # already running. Both land in "cancelled"; the scheduler queries only
    # "scheduled" and "active", so a cancelled window never transitions again.
    update :cancel do
      accept []
      require_atomic? false
      validate attribute_in(:status, ["scheduled", "active"])
      change set_attribute(:status, "cancelled")

      change {Alplus.Audit.Change,
              action: "maintenance.cancel",
              subject_type: "scheduled_maintenance",
              project_id_attribute: :project_id}
    end
  end

  policies do
    policy action(:public_for_page) do
      authorize_if expr(
                     status_page_id == ^actor(:status_page_id) and
                       org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(status_page, exists(public_page, not is_nil(published_at)))
                   )
    end

    policy action(:public_history) do
      authorize_if expr(
                     status_page_id == ^actor(:status_page_id) and
                       org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(status_page, exists(public_page, not is_nil(published_at)))
                   )
    end

    policy action([:read, :for_page]) do
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
      constraints prefix: "mw"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:maintenance_window) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :project_id, Alplus.Id,
      constraints: [prefix: "project"],
      allow_nil?: false,
      public?: true

    attribute :status_page_id, Alplus.Id,
      constraints: [prefix: "sp"],
      allow_nil?: false,
      public?: true

    attribute :title, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 200]

    attribute :description, :string,
      allow_nil?: true,
      public?: true,
      constraints: [max_length: 32_768]

    attribute :starts_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :ends_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :status, :string, allow_nil?: false, default: "scheduled", public?: true
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

    belongs_to :status_page, Alplus.Status.StatusPage,
      source_attribute: :status_page_id,
      define_attribute?: false,
      allow_nil?: false
  end
end
