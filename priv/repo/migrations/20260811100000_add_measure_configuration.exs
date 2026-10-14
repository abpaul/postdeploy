defmodule Alplus.Repo.Migrations.AddMeasureConfiguration do
  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    create table(:goals, primary_key: false) do
      add :id, :text, null: false, primary_key: true
      add :org_id, references(:organizations, type: :text, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :text, on_delete: :delete_all), null: false
      add :name, :text, null: false
      add :kind, :text, null: false
      add :path, :text
      add :event_name, :text
      timestamps(type: :utc_datetime_usec)
    end

    create index(:goals, [:org_id, :project_id])

    execute("""
    ALTER TABLE goals ADD CONSTRAINT goals_shape_check CHECK (
      octet_length(name) BETWEEN 1 AND 120 AND
      kind IN ('pageview', 'event') AND
      ((kind = 'pageview' AND path IS NOT NULL AND event_name IS NULL) OR
       (kind = 'event' AND path IS NULL AND event_name ~ '^[a-z0-9_-]{1,64}$'))
    )
    """)

    create table(:custom_event_definitions, primary_key: false) do
      add :id, :text, null: false, primary_key: true
      add :org_id, references(:organizations, type: :text, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :text, on_delete: :delete_all), null: false
      add :name, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:custom_event_definitions, [:project_id, :name])
    create index(:custom_event_definitions, [:org_id, :project_id])

    execute("""
    ALTER TABLE custom_event_definitions ADD CONSTRAINT custom_event_definitions_name_check
      CHECK (name ~ '^[a-z0-9_-]{1,64}$')
    """)

    execute("""
    CREATE FUNCTION enforce_project_goal_limit() RETURNS trigger AS $$
    BEGIN
      PERFORM pg_advisory_xact_lock(hashtextextended(NEW.project_id, 0));
      IF (SELECT count(*) FROM goals WHERE project_id = NEW.project_id) >= 50 THEN
        RAISE EXCEPTION 'a project can have at most 50 goals';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER goals_limit_before_insert
    BEFORE INSERT ON goals
    FOR EACH ROW EXECUTE FUNCTION enforce_project_goal_limit()
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS goals_limit_before_insert ON goals")
    execute("DROP FUNCTION IF EXISTS enforce_project_goal_limit()")
    drop table(:custom_event_definitions)
    drop table(:goals)
  end
end
