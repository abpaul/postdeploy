defmodule Alplus.Changelog.SourceReference do
  @moduledoc "Private evidence that supports a changelog entry."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Changelog,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "changelog_source_references"
    repo Alplus.Repo

    custom_statements do
      statement :source_reference_caps do
        up """
        ALTER TABLE changelog_source_references
          ADD CONSTRAINT changelog_source_references_kind_check CHECK (kind IN ('pull_request', 'issue', 'release', 'deployment', 'commit', 'other')),
          ADD CONSTRAINT changelog_source_references_url_length_check CHECK (octet_length(url) BETWEEN 1 AND 2048),
          ADD CONSTRAINT changelog_source_references_label_length_check CHECK (label IS NULL OR octet_length(label) <= 200)
        """

        down """
        ALTER TABLE changelog_source_references
          DROP CONSTRAINT changelog_source_references_kind_check,
          DROP CONSTRAINT changelog_source_references_url_length_check,
          DROP CONSTRAINT changelog_source_references_label_length_check
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
      index [:entry_id, :kind, :url],
        unique: true,
        name: "changelog_source_references_entry_url_index"
    end
  end

  actions do
    defaults [:read]

    read :for_entry do
      argument :entry_id, :string, allow_nil?: false
      filter expr(entry_id == ^arg(:entry_id))
    end

    create :create do
      primary? true

      accept [
        :org_id,
        :project_id,
        :changelog_id,
        :entry_id,
        :grant_id,
        :kind,
        :url,
        :label
      ]

      change Alplus.Changelog.Changes.EnforcePlan
    end

    destroy :destroy do
      primary? true
      require_atomic? false
      change Alplus.Changelog.Changes.EnforcePlan
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
      constraints prefix: "cref"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:changelog_source_reference) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: false

    attribute :project_id, Alplus.Id,
      constraints: [prefix: "project"],
      allow_nil?: false,
      public?: false

    attribute :changelog_id, Alplus.Id,
      constraints: [prefix: "clog"],
      allow_nil?: false,
      public?: false

    attribute :entry_id, Alplus.Id,
      constraints: [prefix: "chg"],
      allow_nil?: false,
      public?: false

    # OAuth grant identity. Typed independently of Alplus.Mcp.OAuthGrant.
    attribute :grant_id, Alplus.Id do
      constraints prefix: "mcogr"
      allow_nil? false
      public? false
    end

    attribute :kind, :string, allow_nil?: false, public?: true
    attribute :url, :string, allow_nil?: false, public?: false
    attribute :label, :string, allow_nil?: true, public?: true
    create_timestamp :inserted_at
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
  end
end
