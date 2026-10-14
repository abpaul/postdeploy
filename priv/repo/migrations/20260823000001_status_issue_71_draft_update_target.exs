defmodule Alplus.Repo.Migrations.StatusIssue71DraftUpdateTarget do
  use Ecto.Migration

  def up do
    alter table(:status_incident_drafts) do
      add_if_not_exists :next_update_at, :utc_datetime_usec
    end
  end

  def down do
    alter table(:status_incident_drafts) do
      remove_if_exists :next_update_at
    end
  end
end
