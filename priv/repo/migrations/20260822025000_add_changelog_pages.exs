defmodule Alplus.Repo.Migrations.AddChangelogPages do
  use Ecto.Migration

  def up do
    create table(:changelog_pages, primary_key: false) do
      add :id, :text, null: false, primary_key: true
      add :org_id, references(:organizations, type: :text, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :text, on_delete: :delete_all), null: false
      add :slug, :text, null: false
      add :title, :text, null: false
      add :logo_url, :text
      add :published_at, :utc_datetime_usec

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:changelog_pages, [:slug], name: "changelog_pages_unique_slug_index")
    create unique_index(:changelog_pages, [:project_id], name: "changelog_pages_project_index")

    execute """
    ALTER TABLE changelog_pages
      ADD CONSTRAINT changelog_pages_slug_check CHECK (octet_length(btrim(slug)) BETWEEN 1 AND 80),
      ADD CONSTRAINT changelog_pages_title_check CHECK (octet_length(btrim(title)) BETWEEN 1 AND 200),
      ADD CONSTRAINT changelog_pages_logo_url_check CHECK (logo_url IS NULL OR octet_length(logo_url) <= 2048)
    """

    alter table(:changelog_entries) do
      add :page_id, references(:changelog_pages, type: :text, on_delete: :nilify_all)
    end

    create index(:changelog_entries, [:page_id, :published_at])
  end

  def down do
    drop_if_exists index(:changelog_entries, [:page_id, :published_at])
    alter table(:changelog_entries), do: remove(:page_id)

    execute """
    ALTER TABLE changelog_pages
      DROP CONSTRAINT changelog_pages_slug_check,
      DROP CONSTRAINT changelog_pages_title_check,
      DROP CONSTRAINT changelog_pages_logo_url_check
    """

    drop_if_exists unique_index(:changelog_pages, [:project_id],
                     name: "changelog_pages_project_index"
                   )

    drop_if_exists unique_index(:changelog_pages, [:slug],
                     name: "changelog_pages_unique_slug_index"
                   )

    drop table(:changelog_pages)
  end
end
