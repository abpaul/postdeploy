defmodule Alplus.Changelog.Revision do
  @moduledoc "A Markdown revision for one changelog entry."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Changelog,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "changelog_revisions"
    repo Alplus.Repo

    custom_statements do
      statement :revision_text_caps do
        up """
        ALTER TABLE changelog_revisions
          ADD CONSTRAINT changelog_revisions_markdown_length_check CHECK (octet_length(markdown) BETWEEN 1 AND 100000),
          ADD CONSTRAINT changelog_revisions_status_check CHECK (status IN ('draft', 'published'))
        """

        down """
        ALTER TABLE changelog_revisions
          DROP CONSTRAINT changelog_revisions_markdown_length_check,
          DROP CONSTRAINT changelog_revisions_status_check
        """
      end
    end

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :changelog, on_delete: :delete
      reference :entry, on_delete: :delete
    end

    custom_indexes do
      index [:entry_id, :revision_number],
        unique: true,
        name: "changelog_revisions_entry_number_index"

      index [:project_id, :inserted_at]
    end
  end

  actions do
    defaults [:read]

    read :for_entry do
      argument :entry_id, :string, allow_nil?: false
      filter expr(entry_id == ^arg(:entry_id))
    end

    read :public_for_entry do
      argument :entry_id, :string, allow_nil?: false

      filter expr(
               entry_id == ^arg(:entry_id) and
                 changelog_id == ^actor(:changelog_id) and
                 org_id == ^actor(:org_id) and
                 project_id == ^actor(:project_id) and
                 status == :published
             )
    end

    read :public_for_entries do
      argument :entry_ids, {:array, :string}, allow_nil?: false

      filter expr(
               entry_id in ^arg(:entry_ids) and
                 changelog_id == ^actor(:changelog_id) and
                 org_id == ^actor(:org_id) and
                 project_id == ^actor(:project_id) and
                 status == :published
             )
    end

    read :public_for_vendor_entry do
      argument :entry_id, :string, allow_nil?: false

      filter expr(
               entry_id == ^arg(:entry_id) and
                 changelog_id == ^actor(:changelog_id) and
                 status == :published
             )
    end

    create :create do
      primary? true

      accept [
        :org_id,
        :project_id,
        :changelog_id,
        :entry_id,
        :revision_number,
        :markdown,
        :status
      ]

      change Alplus.Changelog.Changes.EnforcePlan
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:markdown]

      change fn changeset, _context ->
        if changeset.data.status == :published do
          Ash.Changeset.add_error(changeset, message: "published revisions are immutable")
        else
          changeset
        end
      end

      change Alplus.Changelog.Changes.EnforcePlan
    end

    update :publish do
      require_atomic? false
      accept []

      change fn changeset, _context ->
        if changeset.data.status == :published do
          Ash.Changeset.add_error(changeset, message: "published revisions are immutable")
        else
          changeset
          |> Ash.Changeset.force_change_attribute(:status, :published)
          |> Ash.Changeset.force_change_attribute(:published_at, DateTime.utc_now())
        end
      end

      change Alplus.Changelog.Changes.EnforcePlan
    end

    destroy :destroy do
      primary? true
      require_atomic? false
      change Alplus.Changelog.Changes.EnforcePlan
    end
  end

  policies do
    policy action([:read, :for_entry]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:user_id) and role in ["owner", "admin"]
                       )
                   )
    end

    policy action(:publish) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:user_id) and role in ["owner", "admin"]
                       )
                   )
    end

    policy action([:public_for_entry, :public_for_entries]) do
      authorize_if expr(
                     changelog_id == ^actor(:changelog_id) and
                       org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and status == :published
                   )
    end

    policy action(:public_for_vendor_entry) do
      authorize_if expr(changelog_id == ^actor(:changelog_id) and status == :published)
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "crev"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:changelog_revision) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :project_id, Alplus.Id,
      constraints: [prefix: "project"],
      allow_nil?: false,
      public?: true

    attribute :changelog_id, Alplus.Id,
      constraints: [prefix: "clog"],
      allow_nil?: false,
      public?: false

    attribute :entry_id, Alplus.Id,
      constraints: [prefix: "chg"],
      allow_nil?: false,
      public?: true

    attribute :revision_number, :integer, allow_nil?: false, public?: true
    attribute :markdown, :string, allow_nil?: false, public?: true

    attribute :status, :atom,
      constraints: [one_of: [:draft, :published]],
      allow_nil?: false,
      default: :draft,
      public?: true

    attribute :published_at, :utc_datetime_usec,
      allow_nil?: true,
      writable?: false,
      public?: true

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

    belongs_to :changelog, Alplus.Changelog.Changelog,
      source_attribute: :changelog_id,
      define_attribute?: false,
      allow_nil?: false

    belongs_to :entry, Alplus.Changelog.Entry,
      source_attribute: :entry_id,
      define_attribute?: false,
      allow_nil?: false

    has_many :activity_events, Alplus.Changelog.ActivityEvent, destination_attribute: :revision_id
  end
end
