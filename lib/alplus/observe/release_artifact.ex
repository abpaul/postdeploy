defmodule Alplus.Observe.ReleaseArtifact do
  @moduledoc "A release-owned symbolication artifact stored outside Postgres."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Observe,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "release_artifacts"
    repo Alplus.Repo

    custom_indexes do
      index [:release_id, :name], unique: true
      index [:org_id, :project_id, :release_id]
    end

    custom_statements do
      statement :release_artifact_constraints do
        up """
        ALTER TABLE release_artifacts
          ADD CONSTRAINT release_artifacts_name_check CHECK (octet_length(btrim(name)) BETWEEN 1 AND 512),
          ADD CONSTRAINT release_artifacts_type_check CHECK (type IN ('source_map', 'debug_file')),
          ADD CONSTRAINT release_artifacts_storage_key_check CHECK (octet_length(storage_key) BETWEEN 1 AND 1024),
          ADD CONSTRAINT release_artifacts_sha256_check CHECK (sha256 ~ '^[0-9a-f]{64}$'),
          ADD CONSTRAINT release_artifacts_size_check CHECK (byte_size > 0)
        """

        down """
        ALTER TABLE release_artifacts
          DROP CONSTRAINT release_artifacts_name_check,
          DROP CONSTRAINT release_artifacts_type_check,
          DROP CONSTRAINT release_artifacts_storage_key_check,
          DROP CONSTRAINT release_artifacts_sha256_check,
          DROP CONSTRAINT release_artifacts_size_check
        """
      end
    end

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :release, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]

    read :list_for_release do
      argument :release_id, :string, allow_nil?: false

      filter expr(
               org_id == ^actor(:org_id) and
                 project_id == ^actor(:project_id) and
                 release_id == ^arg(:release_id)
             )
    end

    create :create do
      primary? true
      accept [:org_id, :project_id, :release_id, :name, :type, :storage_key, :sha256, :byte_size]
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
      constraints prefix: "art"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:release_artifact) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :project_id, Alplus.Id,
      constraints: [prefix: "project"],
      allow_nil?: false,
      public?: true

    attribute :release_id, Alplus.Id,
      constraints: [prefix: "rel"],
      allow_nil?: false,
      public?: true

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :type, :string, allow_nil?: false, public?: true
    attribute :storage_key, :string, allow_nil?: false, public?: true
    attribute :sha256, :string, allow_nil?: false, public?: true
    attribute :byte_size, :integer, allow_nil?: false, public?: true
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

    belongs_to :release, Alplus.Observe.Release,
      source_attribute: :release_id,
      define_attribute?: false,
      allow_nil?: false
  end
end
