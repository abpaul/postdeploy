defmodule Alplus.Repo.Migrations.ChangelogPublicPageAliases do
  @moduledoc "Preserves legacy Changelog slugs as typed shared-page aliases."

  use Ecto.Migration

  def up do
    execute """
    ALTER TABLE public_page_aliases
      DROP CONSTRAINT IF EXISTS public_page_aliases_kind_check,
      ADD CONSTRAINT public_page_aliases_kind_check
        CHECK (kind IN ('status', 'changelog'))
    """

    execute """
    DO $$
    DECLARE
      changelog_row RECORD;
      identity_row RECORD;
    BEGIN
      FOR changelog_row IN
        SELECT c.id, c.org_id, c.project_id, c.public_slug
        FROM changelogs AS c
        WHERE c.public_slug IS NOT NULL
      LOOP
        SELECT pp.id, pp.public_slug
        INTO identity_row
        FROM public_pages AS pp
        WHERE pp.project_id = changelog_row.project_id
        LIMIT 1;

        IF identity_row.id IS NULL
           OR changelog_row.public_slug = identity_row.public_slug THEN
          CONTINUE;
        END IF;

        IF EXISTS (
          SELECT 1 FROM public_page_aliases
          WHERE public_slug = changelog_row.public_slug
            AND public_page_id <> identity_row.id
        ) THEN
          RAISE EXCEPTION 'legacy public slug collision: %', changelog_row.public_slug;
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM public_pages WHERE public_slug = changelog_row.public_slug
        ) AND NOT EXISTS (
          SELECT 1 FROM public_page_aliases
          WHERE public_slug = changelog_row.public_slug
        ) THEN
          INSERT INTO public_page_aliases (
            id, org_id, project_id, public_page_id, public_slug, kind, source_id,
            inserted_at, updated_at
          )
          VALUES (
            'palias_' || md5(changelog_row.project_id || ':changelog:' || changelog_row.public_slug),
            changelog_row.org_id,
            changelog_row.project_id,
            identity_row.id,
            changelog_row.public_slug,
            'changelog',
            changelog_row.id,
            now() AT TIME ZONE 'utc',
            now() AT TIME ZONE 'utc'
          );
        END IF;
      END LOOP;
    END
    $$;
    """
  end

  def down do
    raise "ChangelogPublicPageAliases is forward-only"
  end
end
