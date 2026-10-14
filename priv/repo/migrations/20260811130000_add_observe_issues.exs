defmodule Alplus.Repo.Migrations.AddObserveIssues do
  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    create table(:issues, primary_key: false) do
      add :id, :text, null: false, primary_key: true
      add :org_id, references(:organizations, type: :text, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :text, on_delete: :delete_all), null: false
      add :environment, :text
      add :fingerprint, :text, null: false
      add :status, :text, null: false, default: "open"
      add :level, :text, null: false
      add :title, :text, null: false
      add :culprit, :text
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
      add :event_count, :bigint, null: false, default: 1
      add :release_first_seen, :text
      add :release_last_seen, :text
      add :context_summary, :map
      add :resolved_at, :utc_datetime_usec
      add :resolved_in_release_id, :text
      add :ignored_until, :utc_datetime_usec
      add :retention_policy_version, :bigint, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:issues, [:org_id, :project_id, :environment, :fingerprint],
             nulls_distinct: false,
             name: :issues_fingerprint_per_environment_index
           )

    create index(:issues, [:org_id, :project_id, :environment, :status, :last_seen_at])

    create index(:issues, [:org_id, :ignored_until],
             where: "status = 'ignored' AND ignored_until IS NOT NULL",
             name: :issues_ignored_until_index
           )

    execute("""
    ALTER TABLE issues
      ADD CONSTRAINT issues_fingerprint_check CHECK (fingerprint ~ '^sha256:[0-9a-f]{64}$'),
      ADD CONSTRAINT issues_environment_check CHECK (environment IS NULL OR octet_length(environment) <= 64),
      ADD CONSTRAINT issues_status_check CHECK (status IN ('open', 'resolved', 'ignored')),
      ADD CONSTRAINT issues_level_check CHECK (level IN ('fatal', 'error', 'warning', 'info')),
      ADD CONSTRAINT issues_title_check CHECK (octet_length(btrim(title)) BETWEEN 1 AND 1024),
      ADD CONSTRAINT issues_culprit_check CHECK (culprit IS NULL OR octet_length(culprit) <= 1024),
      ADD CONSTRAINT issues_release_check CHECK (
        (release_first_seen IS NULL OR octet_length(release_first_seen) <= 200) AND
        (release_last_seen IS NULL OR octet_length(release_last_seen) <= 200)
      ),
      ADD CONSTRAINT issues_event_count_check CHECK (event_count >= 1),
      ADD CONSTRAINT issues_seen_range_check CHECK (last_seen_at >= first_seen_at),
      ADD CONSTRAINT issues_context_summary_check CHECK (context_summary IS NULL OR octet_length(context_summary::text) <= 16384),
      ADD CONSTRAINT issues_resolution_state_check CHECK (
        (status = 'resolved' AND resolved_at IS NOT NULL) OR
        (status <> 'resolved' AND resolved_at IS NULL)
      ),
      ADD CONSTRAINT issues_ignore_state_check CHECK (status = 'ignored' OR ignored_until IS NULL),
      ADD CONSTRAINT issues_retention_policy_check CHECK (retention_policy_version >= 1)
    """)
  end

  def down do
    drop table(:issues)
  end
end
