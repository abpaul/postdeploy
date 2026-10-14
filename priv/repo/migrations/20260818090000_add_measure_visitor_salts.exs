defmodule Alplus.Repo.Migrations.AddMeasureVisitorSalts do
  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    create table(:measure_visitor_salts, primary_key: false) do
      add :day, :date, null: false, primary_key: true
      add :salt, :binary, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end
  end

  def down do
    execute("SET lock_timeout = '3s'")
    drop table(:measure_visitor_salts)
  end
end
