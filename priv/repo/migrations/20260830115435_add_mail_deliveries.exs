defmodule Alplus.Repo.Migrations.AddMailDeliveries do
  use Ecto.Migration

  def change do
    create table(:mail_deliveries, primary_key: false) do
      add :id, :text, primary_key: true
      add :purpose, :text, null: false
      add :record_id, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 1
      add :claim_token, :text
      add :claim_expires_at, :utc_datetime_usec
      add :sent_at, :utc_datetime_usec
      add :error_message, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mail_deliveries, [:purpose, :record_id],
             name: :mail_deliveries_purpose_record_index
           )

    create index(:mail_deliveries, [:claim_expires_at],
             where: "status = 'pending'",
             name: :mail_deliveries_pending_claim_index
           )

    create constraint(:mail_deliveries, :status_check,
             check: "status IN ('pending', 'sent', 'failed')"
           )
  end
end
