defmodule Alplus.Notifications.Delivery do
  @moduledoc """
  Immutable, tenant-scoped external-effect ledger.

  The unique `dedup_key` prevents a restarted notify job from sending the same
  incident or issue notification twice. Only the notification worker may write
  this resource with `authorize?: false`.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Notifications,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "notification_deliveries"
    repo Alplus.Repo

    custom_indexes do
      index [:dedup_key], unique: true, name: "notification_deliveries_dedup_index"
      index [:alert_rule_id, :inserted_at]

      index [:claim_expires_at],
        where: "status IN ('pending', 'failed')",
        name: "notification_deliveries_reclaim_index"
    end

    custom_statements do
      statement :delivery_constraints do
        up """
        ALTER TABLE notification_deliveries
          ADD CONSTRAINT notification_deliveries_channel_type_check CHECK (channel_type IN ('email', 'slack', 'discord', 'webhook', 'telegram')),
          ADD CONSTRAINT notification_deliveries_status_check CHECK (status IN ('pending', 'sent', 'failed', 'skipped')),
          ADD CONSTRAINT notification_deliveries_attempt_check CHECK (attempt >= 1),
          ADD CONSTRAINT notification_deliveries_error_check CHECK (error_message IS NULL OR octet_length(error_message) <= 4096),
          ADD CONSTRAINT notification_deliveries_identity_check CHECK (
            octet_length(btrim(trigger)) BETWEEN 1 AND 120 AND
            octet_length(btrim(dedup_key)) BETWEEN 1 AND 512 AND
            octet_length(btrim(job_id)) BETWEEN 1 AND 255 AND
            octet_length(btrim(claim_token)) BETWEEN 1 AND 255 AND
            (subject_id IS NULL OR octet_length(subject_id) <= 160)
          ),
          ADD CONSTRAINT notification_deliveries_subject_check CHECK (
            (subject_type IS NULL AND subject_id IS NULL) OR
            (subject_type IN ('issue', 'incident', 'monitor', 'project') AND subject_id IS NOT NULL)
          )
        """

        down """
        ALTER TABLE notification_deliveries
          DROP CONSTRAINT notification_deliveries_channel_type_check,
          DROP CONSTRAINT notification_deliveries_status_check,
          DROP CONSTRAINT notification_deliveries_attempt_check,
          DROP CONSTRAINT notification_deliveries_error_check,
          DROP CONSTRAINT notification_deliveries_identity_check,
          DROP CONSTRAINT notification_deliveries_subject_check
        """
      end
    end

    references do
      reference :organization, on_delete: :restrict
      reference :alert_rule, on_delete: :restrict
      reference :channel, on_delete: :restrict
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :org_id,
        :alert_rule_id,
        :channel_id,
        :channel_type,
        :trigger,
        :subject_type,
        :subject_id,
        :dedup_key,
        :job_id,
        :attempt,
        :claimed_at,
        :claim_expires_at,
        :claim_token,
        :status,
        :error_message,
        :sent_at
      ]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:user_id) and role in ["owner", "admin"]
                       )
                   )
    end

    policy action(:record) do
      forbid_if always()
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "ndlv"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:notification_delivery) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :alert_rule_id, Alplus.Id,
      constraints: [prefix: "rule"],
      allow_nil?: true,
      public?: true

    attribute :channel_id, Alplus.Id,
      constraints: [prefix: "chan"],
      allow_nil?: true,
      public?: true

    attribute :channel_type, :string, allow_nil?: false, public?: true
    attribute :trigger, :string, allow_nil?: false, public?: true
    attribute :subject_type, :string, allow_nil?: true, public?: true
    attribute :subject_id, :string, allow_nil?: true, public?: true
    attribute :dedup_key, :string, allow_nil?: false, public?: true
    attribute :job_id, :string, allow_nil?: false, public?: true
    attribute :attempt, :integer, allow_nil?: false, default: 1, public?: true
    attribute :claimed_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :claim_expires_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :claim_token, :string, allow_nil?: false, public?: true
    attribute :status, :string, allow_nil?: false, default: "pending", public?: true
    attribute :error_message, :string, allow_nil?: true, public?: true
    attribute :sent_at, :utc_datetime_usec, allow_nil?: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :organization, Alplus.Orgs.Organization,
      source_attribute: :org_id,
      define_attribute?: false,
      allow_nil?: false

    belongs_to :alert_rule, Alplus.Notifications.AlertRule,
      source_attribute: :alert_rule_id,
      define_attribute?: false,
      allow_nil?: true

    belongs_to :channel, Alplus.Notifications.Channel,
      source_attribute: :channel_id,
      define_attribute?: false,
      allow_nil?: true
  end
end
