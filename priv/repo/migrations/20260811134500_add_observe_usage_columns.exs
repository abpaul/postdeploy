defmodule Alplus.Repo.Migrations.AddObserveUsageColumns do
  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    alter table(:usage_periods) do
      add :error_events, :bigint, null: false, default: 0
      add :dropped_error_events, :bigint, null: false, default: 0
    end

    execute("""
    ALTER TABLE usage_periods ADD CONSTRAINT usage_periods_observe_counts_check
    CHECK (error_events >= 0 AND dropped_error_events >= 0) NOT VALID
    """)

    execute("ALTER TABLE usage_periods VALIDATE CONSTRAINT usage_periods_observe_counts_check")
  end

  def down do
    execute("ALTER TABLE usage_periods DROP CONSTRAINT usage_periods_observe_counts_check")

    alter table(:usage_periods) do
      remove :dropped_error_events
      remove :error_events
    end
  end
end
