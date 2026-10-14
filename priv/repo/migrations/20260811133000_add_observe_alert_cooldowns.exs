defmodule Alplus.Repo.Migrations.AddObserveAlertCooldowns do
  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    create table(:observe_alert_cooldowns, primary_key: false) do
      add :alert_rule_id, references(:alert_rules, type: :text, on_delete: :delete_all),
        null: false

      add :subject_type, :text, null: false
      add :subject_id, :text, null: false
      add :trigger, :text, null: false
      add :last_notified_at, :utc_datetime_usec, null: false
    end

    create unique_index(
             :observe_alert_cooldowns,
             [:alert_rule_id, :subject_type, :subject_id, :trigger],
             name: :observe_alert_cooldowns_identity_index
           )
  end

  def down, do: drop(table(:observe_alert_cooldowns))
end
