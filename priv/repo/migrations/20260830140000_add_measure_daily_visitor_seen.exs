defmodule Alplus.Repo.Migrations.AddMeasureDailyVisitorSeen do
  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    create table(:measure_visitor_seen, primary_key: false) do
      add :day, :date, null: false, primary_key: true

      add :visitor_hash, :string, size: 64, null: false, primary_key: true
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create constraint(:measure_visitor_seen, :measure_visitor_seen_hash_length,
             check: "octet_length(visitor_hash) = 64"
           )
  end

  def down do
    execute("SET lock_timeout = '3s'")
    drop table(:measure_visitor_seen)
  end
end
