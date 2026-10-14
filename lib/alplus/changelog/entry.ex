defmodule Alplus.Changelog.Entry do
  @moduledoc "One agent-managed changelog entry."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Changelog,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "changelog_entries"
    repo Alplus.Repo

    custom_statements do
      statement :entry_text_caps do
        up """
        ALTER TABLE changelog_entries
          ADD CONSTRAINT changelog_entries_external_id_length_check CHECK (octet_length(external_id) BETWEEN 1 AND 255),
          ADD CONSTRAINT changelog_entries_title_length_check CHECK (octet_length(title) BETWEEN 1 AND 200),
          ADD CONSTRAINT changelog_entries_slug_length_check CHECK (public_slug IS NULL OR octet_length(public_slug) BETWEEN 1 AND 100),
          ADD CONSTRAINT changelog_entries_status_check CHECK (status IN ('draft', 'published', 'archived'))
        """

        down """
        ALTER TABLE changelog_entries
          DROP CONSTRAINT changelog_entries_external_id_length_check,
          DROP CONSTRAINT changelog_entries_title_length_check,
          DROP CONSTRAINT changelog_entries_slug_length_check,
          DROP CONSTRAINT changelog_entries_status_check
        """
      end

      statement :entry_public_metadata_caps do
        up """
        ALTER TABLE changelog_entries
          ADD CONSTRAINT changelog_entries_summary_check CHECK (octet_length(btrim(summary)) BETWEEN 1 AND 500),
          ADD CONSTRAINT changelog_entries_area_check CHECK (area IS NULL OR area IN ('monitor', 'observe', 'measure', 'platform')),
          ADD CONSTRAINT changelog_entries_version_check CHECK (version IS NULL OR octet_length(btrim(version)) BETWEEN 1 AND 80),
          ADD CONSTRAINT changelog_entries_media_url_check CHECK (media_url IS NULL OR octet_length(btrim(media_url)) BETWEEN 1 AND 2048),
          ADD CONSTRAINT changelog_entries_media_alt_check CHECK (media_alt IS NULL OR octet_length(btrim(media_alt)) BETWEEN 1 AND 300),
          ADD CONSTRAINT changelog_entries_media_caption_check CHECK (media_caption IS NULL OR octet_length(btrim(media_caption)) BETWEEN 1 AND 300)
        """

        down """
        ALTER TABLE changelog_entries
          DROP CONSTRAINT changelog_entries_summary_check,
          DROP CONSTRAINT changelog_entries_area_check,
          DROP CONSTRAINT changelog_entries_version_check,
          DROP CONSTRAINT changelog_entries_media_url_check,
          DROP CONSTRAINT changelog_entries_media_alt_check,
          DROP CONSTRAINT changelog_entries_media_caption_check
        """
      end
    end

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :changelog, on_delete: :delete
    end

    custom_indexes do
      index [:changelog_id, :grant_id, :external_id],
        unique: true,
        name: "changelog_entries_external_grant_index"

      index [:changelog_id, :public_slug],
        unique: true,
        name: "changelog_entries_public_slug_index",
        where: "public_slug IS NOT NULL"

      index [:project_id, :status, :inserted_at]
      index [:changelog_id, :status, :area, :published_at]
      index [:changelog_id, :status, :version, :published_at]
    end
  end

  actions do
    defaults [:read]

    read :for_project do
      argument :project_id, :string, allow_nil?: false
      filter expr(project_id == ^arg(:project_id))
    end

    read :by_external_id do
      argument :changelog_id, :string, allow_nil?: false
      argument :grant_id, :string, allow_nil?: false
      argument :external_id, :string, allow_nil?: false

      filter expr(
               changelog_id == ^arg(:changelog_id) and
                 grant_id == ^arg(:grant_id) and
                 external_id == ^arg(:external_id)
             )
    end

    read :public_by_slug do
      argument :changelog_id, :string, allow_nil?: false
      argument :slug, :string, allow_nil?: false

      filter expr(
               changelog_id == ^arg(:changelog_id) and
                 public_slug == ^arg(:slug) and
                 status == :published and
                 exists(changelog, exists(public_page, not is_nil(published_at)))
             )
    end

    read :public_for_changelog do
      argument :changelog_id, :string, allow_nil?: false

      filter expr(
               changelog_id == ^arg(:changelog_id) and status == :published and
                 exists(changelog, exists(public_page, not is_nil(published_at)))
             )
    end

    read :public_for_vendor do
      argument :changelog_id, :string, allow_nil?: false

      filter expr(
               changelog_id == ^arg(:changelog_id) and status == :published and
                 exists(changelog, vendor? == true)
             )
    end

    read :read_public do
      filter expr(
               changelog_id == ^actor(:changelog_id) and
                 org_id == ^actor(:org_id) and
                 project_id == ^actor(:project_id) and status == :published and
                 exists(changelog, exists(public_page, not is_nil(published_at)))
             )
    end

    create :create do
      primary? true

      accept [
        :org_id,
        :project_id,
        :changelog_id,
        :grant_id,
        :external_id,
        :title,
        :summary,
        :area,
        :version,
        :media_url,
        :media_alt,
        :media_caption,
        :public_slug,
        :status
      ]

      change Alplus.Changelog.Changes.EnforcePlan
    end

    update :update do
      primary? true
      require_atomic? false

      accept [
        :title,
        :summary,
        :area,
        :version,
        :media_url,
        :media_alt,
        :media_caption,
        :public_slug,
        :status
      ]

      change Alplus.Changelog.Changes.EnforcePlan
    end

    update :publish do
      require_atomic? false

      accept [
        :title,
        :summary,
        :area,
        :version,
        :media_url,
        :media_alt,
        :media_caption,
        :public_slug
      ]

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :published)
        |> Ash.Changeset.force_change_attribute(:published_at, DateTime.utc_now())
      end

      change Alplus.Changelog.Changes.EnforcePlan
    end

    update :archive do
      require_atomic? false
      accept []

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :archived)
      end

      change Alplus.Changelog.Changes.EnforcePlan
    end

    update :restore do
      require_atomic? false
      accept []

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :draft)
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
    policy action([:read, :for_project, :by_external_id]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action_type([:create, :update]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:user_id) and role in ["owner", "admin"]
                       )
                   )
    end

    policy action([:publish, :archive, :restore]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:user_id) and role in ["owner", "admin"]
                       )
                   )
    end

    policy action_type(:destroy) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:user_id) and role in ["owner", "admin"]
                       )
                   )
    end

    policy action([:public_by_slug, :public_for_changelog, :read_public]) do
      authorize_if expr(
                     changelog_id == ^actor(:changelog_id) and
                       org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       status == :published and
                       exists(changelog, exists(public_page, not is_nil(published_at)))
                   )
    end

    policy action(:public_for_vendor) do
      authorize_if expr(
                     changelog_id == ^actor(:changelog_id) and
                       status == :published and
                       exists(changelog, vendor? == true)
                   )
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "chg"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:changelog_entry) end
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

    # Creation/external-id namespace. Not restamped when another grant revises by handle.
    # OAuth grant identity. Typed independently of Alplus.Mcp.OAuthGrant.
    attribute :grant_id, Alplus.Id do
      constraints prefix: "mcogr"
      allow_nil? false
      public? false
    end

    attribute :external_id, :string, allow_nil?: false, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :summary, :string, allow_nil?: false, public?: true
    attribute :area, :string, allow_nil?: true, public?: true
    attribute :version, :string, allow_nil?: true, public?: true
    attribute :media_url, :string, allow_nil?: true, public?: true
    attribute :media_alt, :string, allow_nil?: true, public?: true
    attribute :media_caption, :string, allow_nil?: true, public?: true
    attribute :public_slug, :string, allow_nil?: true, public?: true

    attribute :status, :atom,
      constraints: [one_of: [:draft, :published, :archived]],
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

    has_many :revisions, Alplus.Changelog.Revision, destination_attribute: :entry_id

    has_many :source_references, Alplus.Changelog.SourceReference,
      destination_attribute: :entry_id

    has_many :activity_events, Alplus.Changelog.ActivityEvent, destination_attribute: :entry_id
  end

  aggregates do
    count :source_count, :source_references
  end
end
