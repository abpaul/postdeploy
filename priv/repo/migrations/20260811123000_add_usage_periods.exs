defmodule Alplus.Repo.Migrations.AddUsagePeriods do
  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    create table(:usage_periods, primary_key: false) do
      add :id, :text, null: false, primary_key: true
      add :org_id, references(:organizations, type: :text, on_delete: :delete_all), null: false
      add :period_start, :date, null: false
      add :analytics_events, :bigint, null: false, default: 0
      add :dropped_analytics_events, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:usage_periods, [:org_id, :period_start])

    execute("""
    ALTER TABLE usage_periods ADD CONSTRAINT usage_periods_counts_check CHECK (
      analytics_events >= 0 AND dropped_analytics_events >= 0
    )
    """)
  end

  def down do
    drop table(:usage_periods)
  end
end
