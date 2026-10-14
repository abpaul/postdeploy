defmodule Alplus.Status.StatusAnnouncement do
  @moduledoc "A general public notice that is separate from incident communication."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Status,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "status_announcements"
    repo Alplus.Repo

    custom_statements do
      statement :status_announcement_constraints do
        up """
        ALTER TABLE status_announcements
          ADD CONSTRAINT status_announcements_title_check CHECK (octet_length(btrim(title)) BETWEEN 1 AND 200),
          ADD CONSTRAINT status_announcements_body_check CHECK (octet_length(body) BETWEEN 1 AND 32768),
          ADD CONSTRAINT status_announcements_window_check CHECK (expires_at IS NULL OR expires_at > published_at)
        """

        down """
        ALTER TABLE status_announcements
          DROP CONSTRAINT status_announcements_title_check,
          DROP CONSTRAINT status_announcements_body_check,
          DROP CONSTRAINT status_announcements_window_check
        """
      end
    end

    custom_indexes do
      index [:status_page_id, :published_at]
      index [:org_id, :project_id, :removed_at, :expires_at]
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
                 project_id == ^actor(:project_id) and is_nil(removed_at) and
                 (is_nil(expires_at) or expires_at > ^actor(:now))
             )

      pagination keyset?: true, required?: false
    end

    read :public_history do
      argument :status_page_id, :string, allow_nil?: false

      filter expr(
               status_page_id == ^arg(:status_page_id) and org_id == ^actor(:org_id) and
                 project_id == ^actor(:project_id) and is_nil(removed_at)
             )

      pagination keyset?: true, required?: false
    end

    create :publish do
      primary? true
      accept [:org_id, :project_id, :status_page_id, :title, :body, :expires_at]
      change set_attribute(:published_at, &DateTime.utc_now/0)
      change {Alplus.Status.Changes.PageInScope, page_id_attribute: :status_page_id}

      change {Alplus.Audit.Change,
              action: "status_announcement.publish",
              subject_type: "status_announcement",
              project_id_attribute: :project_id}
    end

    update :update do
      primary? true
      accept [:title, :body, :expires_at]
      require_atomic? false

      change {Alplus.Audit.Change,
              action: "status_announcement.update",
              subject_type: "status_announcement",
              project_id_attribute: :project_id}
    end

    # Unpublishing is reversible: the row stays and `removed_at` (the original
    # storage name) only hides it from `:public_for_page`.
    update :unpublish do
      accept []
      require_atomic? false
      change set_attribute(:removed_at, &DateTime.utc_now/0)

      change {Alplus.Audit.Change,
              action: "status_announcement.unpublish",
              subject_type: "status_announcement",
              project_id_attribute: :project_id}
    end

    update :republish do
      accept []
      require_atomic? false
      change set_attribute(:removed_at, nil)

      change {Alplus.Audit.Change,
              action: "status_announcement.republish",
              subject_type: "status_announcement",
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
      constraints prefix: "sa"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:status_announcement) end
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

    attribute :body, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 32_768]

    attribute :published_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :expires_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :removed_at, :utc_datetime_usec, allow_nil?: true, public?: false
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
