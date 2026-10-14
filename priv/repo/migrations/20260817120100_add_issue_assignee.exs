defmodule Alplus.Repo.Migrations.AddIssueAssignee do
  use Ecto.Migration

  @moduledoc """
  Adds triage ownership: an issue can be assigned to one org member.
  `ON DELETE SET NULL` so removing a user never blocks or cascades into
  issue rows. Membership in the issue's org is enforced by the Ash action,
  not the database.
  """

  def up do
    execute("SET lock_timeout = '3s'")

    execute("""
    ALTER TABLE issues
      ADD COLUMN assignee_id text REFERENCES users(id) ON DELETE SET NULL
    """)

    execute("CREATE INDEX issues_assignee_id_index ON issues (assignee_id)")
  end

  def down do
    execute("DROP INDEX issues_assignee_id_index")
    execute("ALTER TABLE issues DROP COLUMN assignee_id")
  end
end
