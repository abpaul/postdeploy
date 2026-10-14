defmodule Alplus.Repo.Migrations.CutoverMcpOauthGrantIdentity do
  @moduledoc """
  Replaces static MCP credential identity with OAuth grant identity.

  Forward and rollback are valid on empty databases and on databases that
  still have credential-era rows. Leftover credential-only changelog rows
  cannot be remapped to grants and are deleted. Rollback recreates unique
  indexes only after restoring the credential_id columns.
  """

  use Ecto.Migration

  def up do
    drop_if_exists index(:changelog_entries, [:changelog_id, :credential_id, :external_id],
                     name: "changelog_entries_external_credential_index"
                   )

    alter table(:audit_logs) do
      add :grant_id, :text
      remove :credential_id
    end

    alter table(:changelog_activity_events) do
      add :grant_id, :text
      remove :credential_id
    end

    alter table(:changelog_entries) do
      add :grant_id, :text
    end

    alter table(:changelog_source_references) do
      add :grant_id, :text
    end

    flush()

    # Leftover credential-only changelog rows cannot be remapped onto OAuth
    # grants; delete them rather than inventing grant ids.
    execute("DELETE FROM changelog_source_references WHERE grant_id IS NULL")
    execute("DELETE FROM changelog_entries WHERE grant_id IS NULL")

    alter table(:changelog_entries) do
      modify :grant_id, :text, null: false
      remove :credential_id
    end

    alter table(:changelog_source_references) do
      modify :grant_id, :text, null: false
      remove :credential_id
    end

    create index(:changelog_entries, [:changelog_id, :grant_id, :external_id],
             name: "changelog_entries_external_grant_index",
             unique: true
           )
  end

  def down do
    drop_if_exists index(:changelog_entries, [:changelog_id, :grant_id, :external_id],
                     name: "changelog_entries_external_grant_index"
                   )

    alter table(:changelog_source_references) do
      add :credential_id, :text
    end

    alter table(:changelog_entries) do
      add :credential_id, :text
    end

    flush()

    # Leftover grant-only changelog rows cannot be remapped onto credentials;
    # delete them rather than inventing credential ids.
    execute("DELETE FROM changelog_source_references WHERE credential_id IS NULL")
    execute("DELETE FROM changelog_entries WHERE credential_id IS NULL")

    alter table(:changelog_source_references) do
      modify :credential_id, :text, null: false
      remove :grant_id
    end

    alter table(:changelog_entries) do
      modify :credential_id, :text, null: false
      remove :grant_id
    end

    create index(:changelog_entries, [:changelog_id, :credential_id, :external_id],
             name: "changelog_entries_external_credential_index",
             unique: true
           )

    alter table(:changelog_activity_events) do
      add :credential_id, :text
      remove :grant_id
    end

    alter table(:audit_logs) do
      add :credential_id, :text
      remove :grant_id
    end
  end
end
