defmodule Alplus.Repo.Migrations.AddGoalsProjectLookupIndex do
  use Ecto.Migration

  # `CREATE INDEX CONCURRENTLY` cannot run inside a transaction, and it also
  # cannot proceed while the migrator holds its lock transaction open — that
  # deadlocks (the index waits on the migrator's idle-in-transaction
  # connection). Both guards are required, not just the DDL one.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("SET lock_timeout = '0'")

    execute(
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS goals_project_id_index ON goals (project_id)"
    )
  end

  def down do
    execute("SET lock_timeout = '0'")
    execute("DROP INDEX CONCURRENTLY IF EXISTS goals_project_id_index")
  end
end
