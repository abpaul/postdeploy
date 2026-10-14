defmodule Alplus.Changelog.ActivityEvent do
  @moduledoc "Content-free audit event for changelog lifecycle actions."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Changelog,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "changelog_activity_events"
    repo Alplus.Repo

    custom_statements do
      statement :activity_event_caps do
        up """
        ALTER TABLE changelog_activity_events
          ADD CONSTRAINT changelog_activity_events_event_type_length_check CHECK (octet_length(event_type) BETWEEN 1 AND 80),
          ADD CONSTRAINT changelog_activity_events_public_slug_length_check CHECK (public_slug IS NULL OR octet_length(public_slug) <= 100),
          ADD CONSTRAINT changelog_activity_events_correlation_id_length_check CHECK (octet_length(correlation_id) BETWEEN 1 AND 255),
          ADD CONSTRAINT changelog_activity_events_outcome_length_check CHECK (octet_length(outcome) BETWEEN 1 AND 40),
          ADD CONSTRAINT changelog_activity_events_evidence_ids_length_check CHECK (octet_length(evidence_ids::text) <= 10000),
          ADD CONSTRAINT changelog_activity_events_request_metadata_length_check CHECK (octet_length(request_metadata::text) <= 20000)
        """

        down """
        ALTER TABLE changelog_activity_events
          DROP CONSTRAINT changelog_activity_events_event_type_length_check,
          DROP CONSTRAINT changelog_activity_events_public_slug_length_check,
          DROP CONSTRAINT changelog_activity_events_correlation_id_length_check,
          DROP CONSTRAINT changelog_activity_events_outcome_length_check,
          DROP CONSTRAINT changelog_activity_events_evidence_ids_length_check,
          DROP CONSTRAINT changelog_activity_events_request_metadata_length_check
        """
      end
    end

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :changelog, on_delete: :delete
      reference :entry, on_delete: :nilify
      reference :revision, on_delete: :nilify
    end

    custom_indexes do
      index [:project_id, :inserted_at]
    end
  end

  actions do
    defaults [:read]

    read :for_changelog do
      argument :changelog_id, :string, allow_nil?: false
      filter expr(changelog_id == ^arg(:changelog_id))
    end

    read :tombstone_for_slug do
      argument :changelog_id, :string, allow_nil?: false
      argument :slug, :string, allow_nil?: false

      filter expr(
               changelog_id == ^arg(:changelog_id) and
                 event_type == "entry.deleted" and
                 public_slug == ^arg(:slug)
             )
    end

    create :record do
      primary? true

      accept [
        :org_id,
        :project_id,
        :changelog_id,
        :entry_id,
        :revision_id,
        :actor_id,
        :grant_id,
        :event_type,
        :public_slug,
        :evidence_ids,
        :correlation_id,
        :outcome,
        :request_metadata
      ]

      change Alplus.Changelog.Changes.EnforcePlan
    end
  end

  policies do
    policy action([:read, :for_changelog]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action_type(:create) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action(:tombstone_for_slug) do
      authorize_if expr(
                     event_type == "entry.deleted" and
                       org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       changelog_id == ^actor(:changelog_id)
                   )
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "cact"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:changelog_activity_event) end
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
      allow_nil?: true,
      public?: false

    attribute :revision_id, Alplus.Id,
      constraints: [prefix: "crev"],
      allow_nil?: true,
      public?: false

    attribute :actor_id, Alplus.Id,
      constraints: [prefix: "user"],
      allow_nil?: true,
      public?: false

    # OAuth grant identity. Typed independently of Alplus.Mcp.OAuthGrant.
    attribute :grant_id, Alplus.Id do
      constraints prefix: "mcogr"
      allow_nil? true
      public? false
    end

    attribute :event_type, :string, allow_nil?: false, public?: true
    attribute :public_slug, :string, allow_nil?: true, public?: true
    attribute :evidence_ids, {:array, :string}, allow_nil?: false, default: [], public?: false
    attribute :correlation_id, :string, allow_nil?: false, public?: false
    attribute :outcome, :string, allow_nil?: false, public?: true
    attribute :request_metadata, :map, allow_nil?: false, default: %{}, public?: false
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
      allow_nil?: true

    belongs_to :revision, Alplus.Changelog.Revision,
      source_attribute: :revision_id,
      define_attribute?: false,
      allow_nil?: true
  end
end
