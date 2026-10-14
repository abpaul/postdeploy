defmodule Alplus.Observe.Release do
  @moduledoc """
  A deployable application release used to resolve and symbolicate issues.

  Phase A of the Source-scoping rework (issue #46 follow-up, see
  `docs/observe-source-id-phase-b.md`): `source_id` is stamped on every row
  and reads are scoped by it (`AlplusWeb.ObserveDetailLive`), but the
  uniqueness constraint stays on `(org_id, project_id, environment,
  version)` for this deploy.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Observe,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "releases"
    repo Alplus.Repo

    custom_indexes do
      index [:org_id, :project_id, :id], unique: true, name: "releases_scope_id_index"

      # Phase A keeps this unique index on the old `environment` key.
      index [:org_id, :project_id, :environment, :version], unique: true, nulls_distinct: false

      index [:org_id, :project_id, :environment, :released_at]

      # Read-path index only; reads already filter by source_id
      # (AlplusWeb.ObserveDetailLive.load_releases/2).
      index [:org_id, :project_id, :source_id, :released_at],
        name: "releases_source_id_released_at_index"
    end

    custom_statements do
      statement :release_constraints do
        up """
        ALTER TABLE releases
          ADD CONSTRAINT releases_environment_check CHECK (environment IS NULL OR octet_length(environment) <= 64),
          ADD CONSTRAINT releases_version_check CHECK (octet_length(btrim(version)) BETWEEN 1 AND 200),
          ADD CONSTRAINT releases_commit_check CHECK (commit_sha IS NULL OR commit_sha ~ '^[0-9a-f]{7,64}$')
        """

        down """
        ALTER TABLE releases
          DROP CONSTRAINT releases_environment_check,
          DROP CONSTRAINT releases_version_check,
          DROP CONSTRAINT releases_commit_check
        """
      end
    end

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :source, on_delete: :nilify
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
      accept [:org_id, :project_id, :source_id, :environment, :version, :commit_sha, :released_at]
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

    policy action(:create) do
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
      constraints prefix: "rel"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:release) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :project_id, Alplus.Id,
      constraints: [prefix: "project"],
      allow_nil?: false,
      public?: true

    # Nullable at the DB level only for a historical row whose Source was
    # hard-deleted (`ON DELETE SET NULL`) or a pre-backfill row the backfill
    # could not attribute to any Source.
    attribute :source_id, Alplus.Id,
      constraints: [prefix: "source"],
      allow_nil?: true,
      public?: true

    attribute :environment, :string, allow_nil?: true, public?: true
    attribute :version, :string, allow_nil?: false, public?: true
    attribute :commit_sha, :string, allow_nil?: true, public?: true
    attribute :released_at, :utc_datetime_usec, allow_nil?: false, public?: true
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

    belongs_to :source, Alplus.Sources.Source,
      source_attribute: :source_id,
      define_attribute?: false,
      allow_nil?: true
  end
end
