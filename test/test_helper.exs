tables =
  Alplus.Repo.query!("""
  SELECT tablename
  FROM pg_tables
  WHERE schemaname = 'public' AND tablename <> 'schema_migrations'
  """).rows
  |> List.flatten()

Alplus.Repo.query!("TRUNCATE TABLE " <> Enum.join(tables, ", ") <> " CASCADE")

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Alplus.Repo, :manual)
