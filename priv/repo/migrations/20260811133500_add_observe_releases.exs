defmodule Alplus.Repo.Migrations.AddObserveReleases do
  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    create table(:releases, primary_key: false) do
      add :id, :text, null: false, primary_key: true
      add :org_id, references(:organizations, type: :text, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :text, on_delete: :delete_all), null: false
      add :environment, :text
      add :version, :text, null: false
      add :commit_sha, :text
      add :released_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:releases, [:org_id, :project_id, :id], name: :releases_scope_id_index)

    create unique_index(:releases, [:org_id, :project_id, :environment, :version],
             nulls_distinct: false
           )

    create index(:releases, [:org_id, :project_id, :environment, :released_at])

    execute("""
    ALTER TABLE releases
      ADD CONSTRAINT releases_environment_check CHECK (environment IS NULL OR octet_length(environment) <= 64),
      ADD CONSTRAINT releases_version_check CHECK (octet_length(btrim(version)) BETWEEN 1 AND 200),
      ADD CONSTRAINT releases_commit_check CHECK (commit_sha IS NULL OR commit_sha ~ '^[0-9a-f]{7,64}$')
    """)

    create table(:release_artifacts, primary_key: false) do
      add :id, :text, null: false, primary_key: true
      add :org_id, references(:organizations, type: :text, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :text, on_delete: :delete_all), null: false
      add :release_id, references(:releases, type: :text, on_delete: :delete_all), null: false
      add :name, :text, null: false
      add :type, :text, null: false
      add :storage_key, :text, null: false
      add :sha256, :text, null: false
      add :byte_size, :bigint, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:release_artifacts, [:release_id, :name])
    create index(:release_artifacts, [:org_id, :project_id, :release_id])

    execute("""
    ALTER TABLE release_artifacts
      ADD CONSTRAINT release_artifacts_release_scope_fkey
        FOREIGN KEY (org_id, project_id, release_id)
        REFERENCES releases (org_id, project_id, id) ON DELETE CASCADE,
      ADD CONSTRAINT release_artifacts_name_check CHECK (octet_length(btrim(name)) BETWEEN 1 AND 512),
      ADD CONSTRAINT release_artifacts_type_check CHECK (type IN ('source_map', 'debug_file')),
      ADD CONSTRAINT release_artifacts_storage_key_check CHECK (octet_length(storage_key) BETWEEN 1 AND 1024),
      ADD CONSTRAINT release_artifacts_sha256_check CHECK (sha256 ~ '^[0-9a-f]{64}$'),
      ADD CONSTRAINT release_artifacts_size_check CHECK (byte_size > 0)
    """)

    execute("""
    ALTER TABLE issues
      ADD CONSTRAINT issues_resolved_release_scope_fkey
        FOREIGN KEY (org_id, project_id, resolved_in_release_id)
        REFERENCES releases (org_id, project_id, id)
        ON DELETE SET NULL (resolved_in_release_id) NOT VALID
    """)

    execute("ALTER TABLE issues VALIDATE CONSTRAINT issues_resolved_release_scope_fkey")
  end

  def down do
    execute("ALTER TABLE issues DROP CONSTRAINT issues_resolved_release_scope_fkey")
    drop table(:release_artifacts)
    drop table(:releases)
  end
end
