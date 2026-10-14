defmodule Alplus.Repo.Migrations.AddIssueMergedInto do
  use Ecto.Migration

  @moduledoc """
  Issue merging is a reference, not a data move: a merged issue keeps its
  row, fingerprint, and events, and points at the canonical issue. Lists
  hide pointed rows; the canonical page aggregates across them; unmerge
  clears the pointer. Nothing is rewritten, so a merge is always fully
  reversible.
  """

  def up do
    execute("SET lock_timeout = '3s'")

    execute("""
    ALTER TABLE issues
      ADD COLUMN merged_into_issue_id text REFERENCES issues(id) ON DELETE SET NULL
    """)

    execute(
      "CREATE INDEX issues_merged_into_index ON issues (merged_into_issue_id) WHERE merged_into_issue_id IS NOT NULL"
    )
  end

  def down do
    execute("DROP INDEX issues_merged_into_index")
    execute("ALTER TABLE issues DROP COLUMN merged_into_issue_id")
  end
end
