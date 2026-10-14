defmodule Alplus.Repo.Migrations.AddMeasureDailyDimensionRollups do
  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    create table(:analytics_days, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :org_id, references(:organizations, type: :text, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :text, on_delete: :delete_all), null: false
      add :environment, :text, null: false
      add :date, :date, null: false
      add :pageviews, :bigint, null: false, default: 0
      add :visitors, :bigint, null: false, default: 0
      add :visits, :bigint, null: false, default: 0
      add :bounces, :bigint, null: false, default: 0
      add :duration_seconds, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:analytics_days, [:project_id, :environment, :date])
    create index(:analytics_days, [:org_id, :project_id, :date])

    create table(:analytics_dimensions, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :org_id, references(:organizations, type: :text, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :text, on_delete: :delete_all), null: false
      add :environment, :text, null: false
      add :date, :date, null: false
      add :dimension, :text, null: false
      add :value, :text, null: false
      add :visitors, :bigint, null: false, default: 0
      add :pageviews, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:analytics_dimensions, [
             :project_id,
             :environment,
             :date,
             :dimension,
             :value
           ])

    create index(:analytics_dimensions, [:org_id, :project_id, :date, :dimension, :visitors])

    execute("""
    ALTER TABLE analytics_days ADD CONSTRAINT analytics_days_counts_check CHECK (
      pageviews >= 0 AND visitors >= 0 AND visits >= 0 AND bounces >= 0 AND duration_seconds >= 0
    )
    """)

    execute("""
    ALTER TABLE analytics_dimensions ADD CONSTRAINT analytics_dimensions_shape_check CHECK (
      dimension IN ('path', 'hostname', 'event') AND
      octet_length(value) BETWEEN 1 AND 512 AND visitors >= 0 AND pageviews >= 0
    )
    """)
  end

  def down do
    drop table(:analytics_dimensions)
    drop table(:analytics_days)
  end
end
