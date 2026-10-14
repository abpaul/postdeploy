defmodule Alplus.Repo.Migrations.HardenStatusWorkers do
  use Ecto.Migration

  def change do
    alter table(:status_maintenance_monitors) do
      add :paused_by_maintenance, :boolean, null: false, default: false
    end

    create unique_index(:status_incident_updates, [:status_incident_id],
             name: :status_incident_updates_one_recovery,
             where: "kind = 'recovery'"
           )
  end
end
