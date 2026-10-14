defmodule Alplus.Repo.Migrations.StatusWorkspaceSingleton do
  @moduledoc "Consolidates legacy Status pages into one project workspace."

  use Ecto.Migration

  def up do
    create table(:public_page_aliases, primary_key: false) do
      add :id, :text, primary_key: true
      add :org_id, references(:organizations, type: :text, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :text, on_delete: :delete_all), null: false

      add :public_page_id,
          references(:public_pages, type: :text, on_delete: :delete_all),
          null: false

      add :public_slug, :text, null: false
      add :kind, :text, null: false, default: "status"
      add :source_id, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:public_page_aliases, [:public_slug],
             name: "public_page_aliases_slug_unique_index"
           )

    create index(:public_page_aliases, [:org_id, :project_id],
             name: "public_page_aliases_org_project_index"
           )

    execute """
    ALTER TABLE public_page_aliases
      ADD CONSTRAINT public_page_aliases_slug_length_check
        CHECK (octet_length(btrim(public_slug)) BETWEEN 1 AND 100),
      ADD CONSTRAINT public_page_aliases_slug_format_check
        CHECK (public_slug ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'),
      ADD CONSTRAINT public_page_aliases_kind_check
        CHECK (kind IN ('status', 'changelog'))
    """

    execute "CREATE TEMP TABLE status_workspace_migration_counts (
      project_id TEXT NOT NULL,
      relation TEXT NOT NULL,
      source_count BIGINT NOT NULL
    ) ON COMMIT DROP"

    execute """
    DO $$
    DECLARE
      project_row RECORD;
      canonical_row RECORD;
      old_page RECORD;
      old_component RECORD;
      canonical_identity RECORD;
      count_row RECORD;
      old_changelog RECORD;
      destination_count BIGINT;
      next_position INTEGER;
      component_name TEXT;
      suffix_number INTEGER;
    BEGIN
      FOR project_row IN
        SELECT p.id AS project_id, p.org_id
        FROM projects AS p
        WHERE EXISTS (SELECT 1 FROM status_pages AS sp WHERE sp.project_id = p.id)
      LOOP
        SELECT pp.id, pp.public_slug
        INTO canonical_identity
        FROM public_pages AS pp
        WHERE pp.project_id = project_row.project_id
        LIMIT 1;

        IF canonical_identity.id IS NULL THEN
          CONTINUE;
        END IF;

        -- Capture every source relation before staging. The migration must
        -- prove the destination contains the same rows before retiring any
        -- legacy page. Joins and incident history are included explicitly.
        INSERT INTO status_workspace_migration_counts
        SELECT project_row.project_id, 'status_components', count(*)
        FROM status_components
        WHERE project_id = project_row.project_id;
        INSERT INTO status_workspace_migration_counts
        SELECT project_row.project_id, 'status_component_monitors', count(*)
        FROM status_component_monitors
        WHERE project_id = project_row.project_id;
        INSERT INTO status_workspace_migration_counts
        SELECT project_row.project_id, 'status_incidents', count(*)
        FROM status_incidents
        WHERE project_id = project_row.project_id;
        INSERT INTO status_workspace_migration_counts
        SELECT project_row.project_id, 'status_incident_updates', count(*)
        FROM status_incident_updates
        WHERE project_id = project_row.project_id;
        INSERT INTO status_workspace_migration_counts
        SELECT project_row.project_id, 'status_incident_drafts', count(*)
        FROM status_incident_drafts
        WHERE project_id = project_row.project_id;
        INSERT INTO status_workspace_migration_counts
        SELECT project_row.project_id, 'status_incident_services', count(*)
        FROM status_incident_services
        WHERE project_id = project_row.project_id;
        INSERT INTO status_workspace_migration_counts
        SELECT project_row.project_id, 'status_announcements', count(*)
        FROM status_announcements
        WHERE project_id = project_row.project_id;
        INSERT INTO status_workspace_migration_counts
        SELECT project_row.project_id, 'status_scheduled_maintenances', count(*)
        FROM status_scheduled_maintenances
        WHERE project_id = project_row.project_id;

        SELECT sp.id, sp.status_slug
        INTO canonical_row
        FROM status_pages AS sp
        WHERE sp.project_id = project_row.project_id
        ORDER BY
          CASE WHEN sp.published_at IS NULL THEN 1 ELSE 0 END,
          sp.published_at ASC NULLS LAST,
          sp.inserted_at ASC,
          sp.id ASC
        LIMIT 1;

        SELECT COALESCE(MAX(position), -1) + 1
        INTO next_position
        FROM status_components
        WHERE status_page_id = canonical_row.id;

        -- Reserve the old URL even when the canonical identity changed it.
        IF canonical_row.status_slug <> canonical_identity.public_slug
           AND NOT EXISTS (
             SELECT 1 FROM public_pages WHERE public_slug = canonical_row.status_slug
           ) THEN
          IF EXISTS (
            SELECT 1 FROM public_page_aliases
            WHERE public_slug = canonical_row.status_slug
              AND public_page_id <> canonical_identity.id
          ) THEN
            RAISE EXCEPTION 'legacy public slug collision: %', canonical_row.status_slug;
          END IF;

          INSERT INTO public_page_aliases (
            id, org_id, project_id, public_page_id, public_slug, kind, source_id,
            inserted_at, updated_at
          )
          VALUES (
            'palias_' || md5(project_row.project_id || ':' || canonical_row.status_slug),
            project_row.org_id,
            project_row.project_id,
            canonical_identity.id,
            canonical_row.status_slug,
            'status',
            canonical_row.id,
            now() AT TIME ZONE 'utc',
            now() AT TIME ZONE 'utc'
          );
        END IF;

        FOR old_page IN
          SELECT sp.id, sp.status_slug
          FROM status_pages AS sp
          WHERE sp.project_id = project_row.project_id
            AND sp.id <> canonical_row.id
          ORDER BY sp.inserted_at ASC, sp.id ASC
        LOOP
          IF NOT EXISTS (
            SELECT 1 FROM public_pages WHERE public_slug = old_page.status_slug
          ) AND NOT EXISTS (
            SELECT 1 FROM public_page_aliases WHERE public_slug = old_page.status_slug
          ) THEN
            INSERT INTO public_page_aliases (
              id, org_id, project_id, public_page_id, public_slug, kind, source_id,
              inserted_at, updated_at
            )
            VALUES (
              'palias_' || md5(project_row.project_id || ':' || old_page.status_slug || ':' || old_page.id),
              project_row.org_id,
              project_row.project_id,
              canonical_identity.id,
              old_page.status_slug,
              'status',
              old_page.id,
              now() AT TIME ZONE 'utc',
              now() AT TIME ZONE 'utc'
            );
          END IF;

          UPDATE status_incident_drafts
          SET status_page_id = canonical_row.id
          WHERE status_page_id = old_page.id;

          UPDATE status_incidents
          SET status_page_id = canonical_row.id
          WHERE status_page_id = old_page.id;

          UPDATE status_scheduled_maintenances
          SET status_page_id = canonical_row.id
          WHERE status_page_id = old_page.id;

          UPDATE status_announcements
          SET status_page_id = canonical_row.id
          WHERE status_page_id = old_page.id;

          FOR old_component IN
            SELECT sc.id, sc.name
            FROM status_components AS sc
            WHERE sc.status_page_id = old_page.id
            ORDER BY sc.position ASC, sc.inserted_at ASC, sc.id ASC
          LOOP
            component_name := btrim(old_component.name);
            suffix_number := 0;

            -- Never merge customer-facing services. If a name already exists
            -- on the canonical page, retain the legacy service and add a
            -- deterministic suffix based on its source page and ordering.
            WHILE EXISTS (
              SELECT 1
              FROM status_components AS sc
              WHERE sc.status_page_id = canonical_row.id
                AND lower(btrim(sc.name)) = lower(btrim(component_name))
            ) LOOP
              suffix_number := suffix_number + 1;
              component_name := left(btrim(old_component.name), 160)
                || ' (legacy-' || right(old_page.id, 20)
                || CASE WHEN suffix_number > 1 THEN '-' || suffix_number::text ELSE '' END
                || ')';
            END LOOP;

            UPDATE status_components
            SET status_page_id = canonical_row.id,
                name = component_name,
                position = next_position
            WHERE id = old_component.id;

            next_position := next_position + 1;
          END LOOP;

        END LOOP;

        -- Changelog URLs were also public before the shared identity. Keep
        -- every non-canonical Changelog slug as a typed alias before the
        -- contract migration removes changelogs.public_slug.
        FOR old_changelog IN
          SELECT c.id, c.public_slug
          FROM changelogs AS c
          WHERE c.project_id = project_row.project_id
            AND c.public_slug <> canonical_identity.public_slug
          ORDER BY c.inserted_at ASC, c.id ASC
        LOOP
          IF EXISTS (
            SELECT 1 FROM public_page_aliases
            WHERE public_slug = old_changelog.public_slug
              AND public_page_id <> canonical_identity.id
          ) THEN
            RAISE EXCEPTION 'legacy public slug collision: %', old_changelog.public_slug;
          END IF;

          IF NOT EXISTS (
            SELECT 1 FROM public_pages WHERE public_slug = old_changelog.public_slug
          ) AND NOT EXISTS (
            SELECT 1 FROM public_page_aliases
            WHERE public_slug = old_changelog.public_slug
          ) THEN
            INSERT INTO public_page_aliases (
              id, org_id, project_id, public_page_id, public_slug, kind, source_id,
              inserted_at, updated_at
            )
            VALUES (
              'palias_' || md5(project_row.project_id || ':changelog:' || old_changelog.public_slug),
              project_row.org_id,
              project_row.project_id,
              canonical_identity.id,
              old_changelog.public_slug,
              'changelog',
              old_changelog.id,
              now() AT TIME ZONE 'utc',
              now() AT TIME ZONE 'utc'
            );
          END IF;
        END LOOP;

        -- Verify every staged source relation reached the canonical
        -- destination before retiring any legacy page.
        FOR count_row IN
          SELECT relation, source_count
          FROM status_workspace_migration_counts
          WHERE project_id = project_row.project_id
        LOOP
          EXECUTE CASE count_row.relation
            WHEN 'status_components' THEN
              'SELECT count(*) FROM status_components WHERE project_id = $1 AND status_page_id = $2'
            WHEN 'status_component_monitors' THEN
              'SELECT count(*) FROM status_component_monitors WHERE project_id = $1 AND status_component_id IN (SELECT id FROM status_components WHERE project_id = $1 AND status_page_id = $2)'
            WHEN 'status_incidents' THEN
              'SELECT count(*) FROM status_incidents WHERE project_id = $1 AND status_page_id = $2'
            WHEN 'status_incident_updates' THEN
              'SELECT count(*) FROM status_incident_updates WHERE project_id = $1 AND status_incident_id IN (SELECT id FROM status_incidents WHERE project_id = $1 AND status_page_id = $2)'
            WHEN 'status_incident_drafts' THEN
              'SELECT count(*) FROM status_incident_drafts WHERE project_id = $1 AND status_page_id = $2'
            WHEN 'status_incident_services' THEN
              'SELECT count(*) FROM status_incident_services WHERE project_id = $1 AND status_incident_id IN (SELECT id FROM status_incidents WHERE project_id = $1 AND status_page_id = $2)'
            WHEN 'status_announcements' THEN
              'SELECT count(*) FROM status_announcements WHERE project_id = $1 AND status_page_id = $2'
            WHEN 'status_scheduled_maintenances' THEN
              'SELECT count(*) FROM status_scheduled_maintenances WHERE project_id = $1 AND status_page_id = $2'
          END INTO destination_count USING project_row.project_id, canonical_row.id;

          IF destination_count <> count_row.source_count THEN
            RAISE EXCEPTION 'status workspace verification failed for project %, relation %: source %, destination %',
              project_row.project_id, count_row.relation, count_row.source_count, destination_count;
          END IF;
        END LOOP;

        -- The verification above is the gate for retirement. No page is
        -- deleted until all source rows have a canonical destination.
        DELETE FROM status_pages
        WHERE project_id = project_row.project_id
          AND id <> canonical_row.id;
      END LOOP;
    END
    $$;
    """
  end

  def down do
    raise "StatusWorkspaceSingleton is forward-only"
  end
end
