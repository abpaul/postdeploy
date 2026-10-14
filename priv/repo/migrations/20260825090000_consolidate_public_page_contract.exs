defmodule Alplus.Repo.Migrations.ConsolidatePublicPageContract do
  @moduledoc "Retires the split Status and Changelog public-page settings."

  use Ecto.Migration

  # The status table is live when this contract is deployed. PostgreSQL must
  # build the singleton index without taking a write lock for the duration of
  # the index scan.
  @disable_migration_lock true
  @disable_ddl_transaction true

  @doc "Drops legacy settings after the shared public identity is backfilled."
  def up do
    # 20260824100000_status_workspace_singleton has already moved every child
    # row to one Status workspace. Keep that invariant in the database before
    # removing the fields that used to distinguish pages.
    create unique_index(:status_pages, [:project_id],
             name: "status_pages_project_unique_index",
             concurrently: true
           )

    drop_if_exists index(:status_pages, [:status_slug], name: "status_pages_slug_index")

    execute """
    ALTER TABLE status_pages
      DROP CONSTRAINT IF EXISTS status_pages_slug_check,
      DROP CONSTRAINT IF EXISTS status_pages_title_check,
      DROP CONSTRAINT IF EXISTS status_pages_logo_url_check
    """

    alter table(:status_pages) do
      remove :status_slug
      remove :title
      remove :logo_url
      remove :published_at
    end

    drop_if_exists index(:changelogs, [:public_slug], name: "changelogs_unique_public_slug_index")

    execute """
    ALTER TABLE changelogs
      DROP CONSTRAINT IF EXISTS changelogs_public_title_length_check,
      DROP CONSTRAINT IF EXISTS changelogs_public_slug_length_check,
      DROP CONSTRAINT IF EXISTS changelogs_logo_url_length_check,
      DROP CONSTRAINT IF EXISTS changelogs_public_slug_format_check
    """

    alter table(:changelogs) do
      remove :public_title
      remove :public_slug
      remove :logo_url
      remove :enabled
      remove :activated_at
    end
  end

  # This is a forward-only contract migration. Restoring the old columns
  # would create two competing public-page authorities and cannot be safe.
  def down do
    raise "ConsolidatePublicPageContract is forward-only"
  end
end
