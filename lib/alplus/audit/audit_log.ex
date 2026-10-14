defmodule Alplus.Audit.AuditLog do
  @moduledoc """
  One row per sensitive mutation attempt (ARCHITECTURE.md §14 rule 5):
  records the actor, the organization and project where applicable, the
  action, the subject acted on, and whether it was allowed or denied.

  Never insert through this resource directly. `Alplus.Audit.Change`
  attaches to the mutating action being audited and writes the row via
  `Alplus.Audit.write/1` with `authorize?: false` — the `:record` action
  below carries a deny-everything policy on purpose, so no actor code path
  can write a forged row.

  Human and agent audit rows have a real `actor_id`. System automation rows
  use `actor_kind: "system"` and no human identity.

  Never stores a raw IP address: none of the actions audited here are
  "the actor's own" rows (ARCHITECTURE.md §14 rule 5 allows raw IP only on
  an actor's own audit rows, e.g. their own login history — not built in
  this slice). `ip_address` stays nil until that case exists.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "audit_logs"
    repo Alplus.Repo

    custom_statements do
      statement :action_length_check do
        up "ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_action_length_check CHECK (octet_length(action) <= 64)"
        down "ALTER TABLE audit_logs DROP CONSTRAINT audit_logs_action_length_check"
      end

      statement :subject_type_length_check do
        up "ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_subject_type_length_check CHECK (octet_length(subject_type) <= 32)"
        down "ALTER TABLE audit_logs DROP CONSTRAINT audit_logs_subject_type_length_check"
      end

      statement :subject_id_length_check do
        up "ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_subject_id_length_check CHECK (subject_id IS NULL OR octet_length(subject_id) <= 64)"
        down "ALTER TABLE audit_logs DROP CONSTRAINT audit_logs_subject_id_length_check"
      end

      statement :outcome_check do
        up "ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_outcome_check CHECK (outcome IN ('allowed', 'denied'))"
        down "ALTER TABLE audit_logs DROP CONSTRAINT audit_logs_outcome_check"
      end

      statement :actor_kind_check do
        up "ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_actor_kind_check CHECK (actor_kind IN ('user', 'agent', 'system'))"
        down "ALTER TABLE audit_logs DROP CONSTRAINT audit_logs_actor_kind_check"
      end

      statement :actor_identity_check do
        up """
        ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_actor_identity_check CHECK (
          (actor_kind = 'system' AND actor_id IS NULL) OR
          (actor_kind IN ('user', 'agent') AND actor_id IS NOT NULL)
        )
        """

        down "ALTER TABLE audit_logs DROP CONSTRAINT audit_logs_actor_identity_check"
      end

      statement :transport_check do
        up "ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_transport_check CHECK (transport IN ('session', 'remote_mcp', 'webmcp', 'automation'))"
        down "ALTER TABLE audit_logs DROP CONSTRAINT audit_logs_transport_check"
      end

      statement :metadata_length_check do
        up "ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_metadata_length_check CHECK (octet_length(metadata::text) <= 8192)"
        down "ALTER TABLE audit_logs DROP CONSTRAINT audit_logs_metadata_length_check"
      end

      statement :user_agent_length_check do
        up "ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_user_agent_length_check CHECK (user_agent IS NULL OR octet_length(user_agent) <= 512)"
        down "ALTER TABLE audit_logs DROP CONSTRAINT audit_logs_user_agent_length_check"
      end
    end

    references do
      # `:delete`: destroying an org erases its entire audit trail with it
      # (founder decision — GDPR-style right to erasure, not a preserved
      # trail). `Alplus.Audit.Change` skips writing the `organization
      # .destroy` row itself for the same reason: it would be erased by
      # this same cascade the instant it landed, so there is nothing to
      # write into.
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :actor, on_delete: :delete
    end
  end

  actions do
    read :read do
      primary? true
      pagination keyset?: true, required?: false, default_limit: 25, max_page_size: 25
    end

    create :record do
      description "System-only write. Called by Alplus.Audit.write/1 with authorize?: false."

      accept [
        :org_id,
        :project_id,
        :actor_id,
        :grant_id,
        :actor_kind,
        :transport,
        :action,
        :subject_type,
        :subject_id,
        :outcome,
        :metadata,
        :request_id,
        :user_agent
      ]
    end
  end

  policies do
    # No actor-facing write path exists on purpose: `write/1` always calls
    # `Ash.create(..., action: :record, authorize?: false)`. This policy is
    # defense in depth, matching Membership's `create_owner` convention —
    # deny by default, never authorize a direct actor write.
    policy action_type(:create) do
      forbid_if always()
    end

    policy action_type(:read) do
      authorize_if expr(
                     exists(
                       organization.memberships,
                       user_id == ^actor(:user_id) and role in ["owner", "admin"]
                     )
                   )
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "audit"
      public? true
      writable? false
      primary_key? true
      allow_nil? false
      default fn -> Alplus.Id.generate("audit") end
    end

    attribute :org_id, Alplus.Id do
      constraints prefix: "organization"
      public? true
      allow_nil? false
      writable? true
    end

    attribute :project_id, Alplus.Id do
      constraints prefix: "project"
      public? true
      allow_nil? true
      writable? true
    end

    attribute :actor_id, Alplus.Id do
      constraints prefix: "user"
      public? true
      allow_nil? true
      writable? true
    end

    # OAuth grant identity. Nil for browser-session actors.
    attribute :grant_id, Alplus.Id do
      constraints prefix: "mcogr"
      public? true
      allow_nil? true
      writable? true
    end

    attribute :actor_kind, :string do
      allow_nil? false
      public? true
      default "user"
      constraints match: ~r/\A(user|agent|system)\z/
    end

    attribute :transport, :string do
      allow_nil? false
      public? true
      default "session"
      constraints match: ~r/\A(session|remote_mcp|webmcp|automation)\z/
    end

    attribute :action, :string do
      allow_nil? false
      public? true
      constraints max_length: 64
    end

    attribute :subject_type, :string do
      allow_nil? false
      public? true
      constraints max_length: 32
    end

    attribute :subject_id, :string do
      allow_nil? true
      public? true
      constraints max_length: 64
    end

    attribute :outcome, :string do
      allow_nil? false
      public? true
      constraints match: ~r/\A(allowed|denied)\z/
    end

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    # Never populated by Alplus.Audit.Change (see moduledoc). Present so the
    # schema matches ARCHITECTURE.md §14 rule 5's "actor's own rows" carve-out
    # when that case is built.
    attribute :ip_address, :string do
      allow_nil? true
      public? true
    end

    attribute :request_id, :string do
      allow_nil? true
      public? true
      constraints max_length: 64
    end

    attribute :user_agent, :string do
      allow_nil? true
      public? true
      constraints max_length: 512
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :organization, Alplus.Orgs.Organization do
      source_attribute :org_id
      define_attribute? false
      allow_nil? false
    end

    belongs_to :project, Alplus.Projects.Project do
      source_attribute :project_id
      define_attribute? false
      allow_nil? true
    end

    belongs_to :actor, Alplus.Accounts.User do
      source_attribute :actor_id
      define_attribute? false
      allow_nil? true
    end
  end
end
