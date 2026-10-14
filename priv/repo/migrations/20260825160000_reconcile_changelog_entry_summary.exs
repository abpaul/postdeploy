defmodule Alplus.Repo.Migrations.ReconcileChangelogEntrySummary do
  @moduledoc """
  Restores the `summary` column that `20260823104206` gained after production
  had already run it. Databases created from the current file already have
  the column and the constraint, so both statements are no-ops there.
  `20260825162847` then backfills the column and makes it NOT NULL.
  """

  use Ecto.Migration

  def up do
    execute("ALTER TABLE changelog_entries ADD COLUMN IF NOT EXISTS summary text")

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'changelog_entries_summary_check'
          AND conrelid = 'changelog_entries'::regclass
      ) THEN
        ALTER TABLE changelog_entries
          ADD CONSTRAINT changelog_entries_summary_check
            CHECK (octet_length(btrim(summary)) BETWEEN 1 AND 500);
      END IF;
    END
    $$
    """)
  end

  # The column belongs to `20260823104206`, whose `down` removes it.
  def down, do: :ok
end
