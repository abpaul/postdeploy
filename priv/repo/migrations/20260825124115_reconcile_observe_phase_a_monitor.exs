defmodule Alplus.Repo.Migrations.ReconcileObservePhaseAMonitor do
  @moduledoc """
  Adds the Monitor SLO target and the non-destructive Observe/Measure indexes.

  This migration is intentionally idempotent because the shared worktree may
  already have one or more of these objects from an earlier local run.
  """

  use Ecto.Migration

  def up do
    create_if_not_exists index(:releases, [:org_id, :project_id, :environment, :version],
                           unique: true,
                           nulls_distinct: false
                         )

    create_if_not_exists index(:issues, [:org_id, :project_id, :environment, :fingerprint],
                           name: "issues_fingerprint_per_environment_index",
                           unique: true,
                           nulls_distinct: false
                         )

    execute("ALTER TABLE monitors ADD COLUMN IF NOT EXISTS slo_target double precision")

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'monitors_slo_target_check'
          AND conrelid = 'monitors'::regclass
      ) THEN
        ALTER TABLE monitors
          ADD CONSTRAINT monitors_slo_target_check
          CHECK (slo_target IS NULL OR (slo_target > 0 AND slo_target <= 1));
      END IF;
    END $$;
    """)
  end

  def down do
    :ok
  end
end
