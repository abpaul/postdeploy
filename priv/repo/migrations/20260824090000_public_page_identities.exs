defmodule Alplus.Repo.Migrations.PublicPageIdentities do
  @moduledoc """
  Adds the shared public-page identity beside the legacy Status and Changelog
  fields, and backfills one identity for every project with a public surface.

  The data step preserves the oldest published status page first, then the
  oldest draft status page, then the existing changelog. A slug collision keeps
  the first decision and displaces the next project with its public token.
  """

  use Ecto.Migration

  def up do
    create table(:public_pages, primary_key: false) do
      add :id, :text, primary_key: true
      add :org_id, references(:organizations, type: :text, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :text, on_delete: :delete_all), null: false
      add :public_slug, :text, null: false
      add :title, :text, null: false
      add :logo_url, :text
      add :published_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:public_pages, [:project_id], name: "public_pages_project_unique_index")
    create unique_index(:public_pages, [:public_slug], name: "public_pages_slug_unique_index")
    create index(:public_pages, [:org_id, :project_id], name: "public_pages_org_project_index")

    execute """
    ALTER TABLE public_pages
      ADD CONSTRAINT public_pages_slug_length_check
        CHECK (octet_length(btrim(public_slug)) BETWEEN 1 AND 100),
      ADD CONSTRAINT public_pages_slug_format_check
        CHECK (public_slug ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'),
      ADD CONSTRAINT public_pages_title_length_check
        CHECK (octet_length(btrim(title)) BETWEEN 1 AND 200),
      ADD CONSTRAINT public_pages_logo_url_length_check
        CHECK (logo_url IS NULL OR octet_length(logo_url) BETWEEN 1 AND 2048)
    """

    execute """
    DO $$
    DECLARE
      project_row RECORD;
      source_row RECORD;
      candidate_slug TEXT;
      displaced_slug TEXT;
      suffix_number INTEGER;
      publication_time TIMESTAMPTZ;
    BEGIN
      FOR project_row IN
        SELECT p.id, p.org_id, p.public_token
        FROM projects AS p
        WHERE EXISTS (SELECT 1 FROM status_pages AS sp WHERE sp.project_id = p.id)
           OR EXISTS (SELECT 1 FROM changelogs AS c WHERE c.project_id = p.id)
        ORDER BY
          CASE
            WHEN EXISTS (
              SELECT 1 FROM status_pages AS sp
              WHERE sp.project_id = p.id AND sp.published_at IS NOT NULL
            ) THEN 0
            WHEN EXISTS (
              SELECT 1 FROM status_pages AS sp
              WHERE sp.project_id = p.id AND sp.published_at IS NULL
            ) THEN 1
            ELSE 2
          END,
          COALESCE(
            (SELECT min(sp.published_at) FROM status_pages AS sp
             WHERE sp.project_id = p.id AND sp.published_at IS NOT NULL),
            (SELECT min(sp.inserted_at) FROM status_pages AS sp
             WHERE sp.project_id = p.id AND sp.published_at IS NULL),
            (SELECT min(c.inserted_at) FROM changelogs AS c WHERE c.project_id = p.id)
          ),
          p.id
      LOOP
        SELECT
          sources.source_slug,
          sources.source_title,
          sources.source_logo_url,
          sources.source_rank,
          sources.source_time,
          sources.source_id
        INTO source_row
        FROM (
          SELECT sp.status_slug AS source_slug,
                 sp.title AS source_title,
                 sp.logo_url AS source_logo_url,
                 0 AS source_rank,
                 sp.published_at AS source_time,
                 sp.id AS source_id
          FROM status_pages AS sp
          WHERE sp.project_id = project_row.id AND sp.published_at IS NOT NULL
          UNION ALL
          SELECT sp.status_slug,
                 sp.title,
                 sp.logo_url,
                 1,
                 sp.inserted_at,
                 sp.id
          FROM status_pages AS sp
          WHERE sp.project_id = project_row.id AND sp.published_at IS NULL
          UNION ALL
          SELECT c.public_slug,
                 c.public_title,
                 c.logo_url,
                 2,
                 c.inserted_at,
                 c.id
          FROM changelogs AS c
          WHERE c.project_id = project_row.id
        ) AS sources
        ORDER BY sources.source_rank, sources.source_time NULLS LAST, sources.source_id
        LIMIT 1;

        candidate_slug := rtrim(left(source_row.source_slug, 100), '-');

        IF EXISTS (
          SELECT 1 FROM public_pages
          WHERE public_slug = candidate_slug AND project_id <> project_row.id
        ) OR EXISTS (
          SELECT 1 FROM status_pages
          WHERE status_slug = candidate_slug AND project_id <> project_row.id
        ) OR EXISTS (
          SELECT 1 FROM changelogs
          WHERE public_slug = candidate_slug AND project_id <> project_row.id
        ) THEN
          displaced_slug := left(
            btrim(candidate_slug, '-'),
            greatest(1, 100 - length('-' || lower(COALESCE(project_row.public_token, 'project'))))
          ) || '-' || lower(COALESCE(project_row.public_token, 'project'));
          suffix_number := 2;

          WHILE EXISTS (
            SELECT 1 FROM public_pages WHERE public_slug = displaced_slug
          ) OR EXISTS (
            SELECT 1 FROM status_pages
            WHERE status_slug = displaced_slug AND project_id <> project_row.id
          ) OR EXISTS (
            SELECT 1 FROM changelogs
            WHERE public_slug = displaced_slug AND project_id <> project_row.id
          ) LOOP
            displaced_slug := left(
              btrim(candidate_slug, '-'),
              greatest(1, 100 - length('-' || lower(COALESCE(project_row.public_token, 'project')) || '-' || suffix_number::text))
            ) || '-' || lower(COALESCE(project_row.public_token, 'project')) || '-' || suffix_number::text;
            suffix_number := suffix_number + 1;
          END LOOP;

          candidate_slug := displaced_slug;
        END IF;

        publication_time := NULL;
        IF source_row.source_rank = 0 THEN
          publication_time := source_row.source_time;
        ELSIF source_row.source_rank = 2 THEN
          SELECT c.activated_at INTO publication_time
          FROM changelogs AS c
          WHERE c.id = source_row.source_id AND c.enabled = TRUE;
        END IF;

        INSERT INTO public_pages (
          id, org_id, project_id, public_slug, title, logo_url, published_at,
          inserted_at, updated_at
        )
        VALUES (
          'ppage_' || substring(project_row.id from position('_' in project_row.id) + 1),
          project_row.org_id,
          project_row.id,
          candidate_slug,
          source_row.source_title,
          source_row.source_logo_url,
          publication_time,
          now() AT TIME ZONE 'utc',
          now() AT TIME ZONE 'utc'
        );
      END LOOP;
    END
    $$;
    """
  end

  def down do
    raise "PublicPageIdentities is forward-only"
  end
end
