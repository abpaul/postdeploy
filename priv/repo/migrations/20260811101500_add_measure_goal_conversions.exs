defmodule Alplus.Repo.Migrations.AddMeasureGoalConversions do
  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    create table(:goal_conversions, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :org_id, references(:organizations, type: :text, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :text, on_delete: :delete_all), null: false
      add :goal_id, references(:goals, type: :text, on_delete: :delete_all), null: false
      add :environment, :text, null: false
      add :hour, :utc_datetime_usec, null: false
      add :conversions, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:goal_conversions, [:goal_id, :environment, :hour])
    create index(:goal_conversions, [:org_id, :project_id, :hour])

    execute(
      "ALTER TABLE goal_conversions ADD CONSTRAINT goal_conversions_count_check CHECK (conversions >= 0)"
    )
  end

  def down do
    drop table(:goal_conversions)
  end
end
