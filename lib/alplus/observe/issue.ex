defmodule Alplus.Observe.Issue do
  @moduledoc """
  A tenant-scoped error group. The ingest path owns event upserts; this
  resource owns durable human lifecycle transitions.

  Phase A of the Source-scoping rework (issue #46 follow-up, see
  `docs/observe-source-id-phase-b.md`): `source_id` is now stamped on every
  ingest-written row and every read is scoped by it
  (`Alplus.Observe.EventWriter`, `Alplus.Observe.Dashboard`,
  `AlplusWeb.ObserveDetailLive`). The uniqueness constraint and the ingest
  writer's `ON CONFLICT` target stay on `(org_id, project_id, environment,
  fingerprint)` for this deploy. `source_id` is nullable at the database
  level because a historical row can outlive its Source (`ON DELETE SET
  NULL`), never because a live ingest write may omit it.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Observe,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine]

  postgres do
    table "issues"
    repo Alplus.Repo

    custom_indexes do
      # Phase A keeps this unique index on the old `environment` key.
      index [:org_id, :project_id, :environment, :fingerprint],
        unique: true,
        nulls_distinct: false,
        name: "issues_fingerprint_per_environment_index"

      index [:org_id, :project_id, :environment, :status, :last_seen_at]

      # Read-path index only; the ingest writer's conflict target stays
      # environment-keyed until Phase B.
      index [:org_id, :project_id, :source_id, :status, :last_seen_at],
        name: "issues_source_id_status_last_seen_index"

      index [:org_id, :ignored_until],
        where: "status = 'ignored' AND ignored_until IS NOT NULL",
        name: "issues_ignored_until_index"
    end

    custom_statements do
      statement :issue_constraints do
        up """
        ALTER TABLE issues
          ADD CONSTRAINT issues_fingerprint_check CHECK (fingerprint ~ '^sha256:[0-9a-f]{64}$'),
          ADD CONSTRAINT issues_environment_check CHECK (environment IS NULL OR octet_length(environment) <= 64),
          ADD CONSTRAINT issues_status_check CHECK (status IN ('open', 'resolved', 'ignored')),
          ADD CONSTRAINT issues_level_check CHECK (level IN ('fatal', 'error', 'warning', 'info')),
          ADD CONSTRAINT issues_title_check CHECK (octet_length(btrim(title)) BETWEEN 1 AND 1024),
          ADD CONSTRAINT issues_culprit_check CHECK (culprit IS NULL OR octet_length(culprit) <= 1024),
          ADD CONSTRAINT issues_release_check CHECK (
            (release_first_seen IS NULL OR octet_length(release_first_seen) <= 200) AND
            (release_last_seen IS NULL OR octet_length(release_last_seen) <= 200)
          ),
          ADD CONSTRAINT issues_event_count_check CHECK (event_count >= 1),
          ADD CONSTRAINT issues_seen_range_check CHECK (last_seen_at >= first_seen_at),
          ADD CONSTRAINT issues_context_summary_check CHECK (context_summary IS NULL OR octet_length(context_summary::text) <= 16384),
          ADD CONSTRAINT issues_resolution_state_check CHECK (
            (status = 'resolved' AND resolved_at IS NOT NULL) OR
            (status <> 'resolved' AND resolved_at IS NULL)
          ),
          ADD CONSTRAINT issues_ignore_state_check CHECK (status = 'ignored' OR ignored_until IS NULL),
          ADD CONSTRAINT issues_retention_policy_check CHECK (retention_policy_version >= 1)
        """

        down """
        ALTER TABLE issues
          DROP CONSTRAINT issues_fingerprint_check,
          DROP CONSTRAINT issues_environment_check,
          DROP CONSTRAINT issues_status_check,
          DROP CONSTRAINT issues_level_check,
          DROP CONSTRAINT issues_title_check,
          DROP CONSTRAINT issues_culprit_check,
          DROP CONSTRAINT issues_release_check,
          DROP CONSTRAINT issues_event_count_check,
          DROP CONSTRAINT issues_seen_range_check,
          DROP CONSTRAINT issues_context_summary_check,
          DROP CONSTRAINT issues_resolution_state_check,
          DROP CONSTRAINT issues_ignore_state_check,
          DROP CONSTRAINT issues_retention_policy_check
        """
      end
    end

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :source, on_delete: :nilify
    end
  end

  state_machine do
    state_attribute :status
    initial_states [:open]
    default_initial_state :open

    transitions do
      transition :resolve, from: :open, to: :resolved
      transition :ignore, from: [:open, :resolved], to: :ignored
      transition :regress, from: [:resolved, :ignored], to: :open
      transition :reopen, from: [:resolved, :ignored], to: :open
    end
  end

  actions do
    defaults [:read]

    read :list_for_project do
      argument :project_id, :string, allow_nil?: false
      filter expr(org_id == ^actor(:org_id) and project_id == ^arg(:project_id))
    end

    read :list_for_projects do
      argument :project_ids, {:array, :string}, allow_nil?: false
      filter expr(org_id == ^actor(:org_id) and project_id in ^arg(:project_ids))
    end

    read :exists_for_projects do
      argument :project_ids, {:array, :string}, allow_nil?: false
      filter expr(org_id == ^actor(:org_id) and project_id in ^arg(:project_ids))
    end

    # This action is called only by the transaction-owned direct ingest path.
    # Browser requests never receive a policy that permits it.
    read :list_public_for_vendor do
      filter expr(
               org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                 environment == "production" and status == :open
             )

      # The homepage only needs a bounded count, never issue payloads.
      prepare build(select: [:id], sort: [id: :asc], limit: 100)
    end

    create :record do
      accept [
        :org_id,
        :project_id,
        :source_id,
        :environment,
        :fingerprint,
        :level,
        :title,
        :culprit,
        :first_seen_at,
        :last_seen_at,
        :event_count,
        :release_first_seen,
        :release_last_seen,
        :context_summary
      ]
    end

    update :resolve do
      accept [:resolved_in_release_id]
      require_atomic? false
      change transition_state(:resolved)
      change set_attribute(:resolved_at, &DateTime.utc_now/0)
      change set_attribute(:ignored_until, nil)

      change {Alplus.Audit.Change,
              action: "issue.resolve", subject_type: "issue", project_id_attribute: :project_id}
    end

    update :ignore do
      accept []
      require_atomic? false
      change transition_state(:ignored)
      change set_attribute(:resolved_at, nil)
      change set_attribute(:resolved_in_release_id, nil)
      change Alplus.Observe.Issue.Changes.SetIgnoredUntil

      change {Alplus.Audit.Change,
              action: "issue.ignore", subject_type: "issue", project_id_attribute: :project_id}
    end

    update :regress do
      accept [:last_seen_at, :event_count, :release_last_seen]
      require_atomic? false
      change transition_state(:open)
      change set_attribute(:resolved_at, nil)
      change set_attribute(:resolved_in_release_id, nil)
      change set_attribute(:ignored_until, nil)
    end

    # The human counterpart to :regress. Kept separate so the automatic
    # ingest-driven reopen (never reachable from a browser actor) and the
    # owner/admin-initiated reopen stay independently authorizable and
    # independently audited.
    update :reopen do
      accept []
      require_atomic? false
      change transition_state(:open)
      change set_attribute(:resolved_at, nil)
      change set_attribute(:resolved_in_release_id, nil)
      change set_attribute(:ignored_until, nil)

      change {Alplus.Audit.Change,
              action: "issue.reopen", subject_type: "issue", project_id_attribute: :project_id}
    end

    # Merge is a pointer, not a data move: this issue keeps its row,
    # fingerprint, and events, and lists hide it while the canonical issue
    # aggregates it. Unmerge clears the pointer, fully restoring it.
    update :merge do
      accept [:merged_into_issue_id]
      require_atomic? false
      validate Alplus.Observe.Issue.Validations.MergeTargetValid

      change {Alplus.Audit.Change,
              action: "issue.merge", subject_type: "issue", project_id_attribute: :project_id}
    end

    update :unmerge do
      accept []
      require_atomic? false
      change set_attribute(:merged_into_issue_id, nil)

      change {Alplus.Audit.Change,
              action: "issue.unmerge", subject_type: "issue", project_id_attribute: :project_id}
    end

    # Triage ownership. `assignee_id` must be a member of the issue's org
    # (validated below); nil unassigns. Any status accepts an assignment —
    # assigning a resolved issue is a normal "you own the follow-up" move.
    update :assign do
      accept [:assignee_id]
      require_atomic? false
      validate Alplus.Observe.Issue.Validations.AssigneeIsOrgMember

      change {Alplus.Audit.Change,
              action: "issue.assign", subject_type: "issue", project_id_attribute: :project_id}
    end

    destroy :destroy do
      require_atomic? false

      change {Alplus.Audit.Change,
              action: "issue.destroy", subject_type: "issue", project_id_attribute: :project_id}
    end
  end

  policies do
    policy action([:read, :list_for_project]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action(:list_public_for_vendor) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       environment == "production"
                   )
    end

    policy action([:list_for_projects, :exists_for_projects]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action([:resolve, :ignore, :reopen, :assign, :merge, :unmerge, :destroy]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:user_id) and role in ["owner", "admin"]
                       )
                   )
    end

    policy action([:record, :regress]) do
      forbid_if always()
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "iss"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:issue) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :project_id, Alplus.Id,
      constraints: [prefix: "project"],
      allow_nil?: false,
      public?: true

    # Nullable at the DB level only for a historical row whose Source was
    # hard-deleted (`ON DELETE SET NULL`) or a pre-backfill row the backfill
    # could not attribute to any Source. Every ingest-written row carries a
    # real value.
    attribute :source_id, Alplus.Id,
      constraints: [prefix: "source"],
      allow_nil?: true,
      public?: true

    attribute :environment, :string, allow_nil?: true, public?: true
    attribute :fingerprint, :string, allow_nil?: false, public?: true

    attribute :status, :atom,
      constraints: [one_of: [:open, :resolved, :ignored]],
      allow_nil?: false,
      default: :open,
      public?: true

    attribute :level, :string, allow_nil?: false, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :culprit, :string, allow_nil?: true, public?: true
    attribute :first_seen_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :last_seen_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :event_count, :integer, allow_nil?: false, default: 1, public?: true
    attribute :release_first_seen, :string, allow_nil?: true, public?: true
    attribute :release_last_seen, :string, allow_nil?: true, public?: true
    attribute :context_summary, :map, allow_nil?: true, public?: true
    attribute :resolved_at, :utc_datetime_usec, allow_nil?: true, public?: true, writable?: false

    # Releases are added by the release resource. Keep the durable foreign-key
    # column here so resolve and regression have a stable integration seam.
    attribute :resolved_in_release_id, Alplus.Id,
      constraints: [prefix: "rel"],
      allow_nil?: true,
      public?: true

    attribute :ignored_until, :utc_datetime_usec,
      allow_nil?: true,
      public?: true

    attribute :retention_policy_version, :integer, allow_nil?: false, default: 1, public?: true

    attribute :assignee_id, Alplus.Id do
      constraints prefix: "user"
      allow_nil? true
      public? true
    end

    attribute :merged_into_issue_id, Alplus.Id do
      constraints prefix: "iss"
      allow_nil? true
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :organization, Alplus.Orgs.Organization,
      source_attribute: :org_id,
      define_attribute?: false,
      allow_nil?: false

    belongs_to :project, Alplus.Projects.Project,
      source_attribute: :project_id,
      define_attribute?: false,
      allow_nil?: false

    belongs_to :source, Alplus.Sources.Source,
      source_attribute: :source_id,
      define_attribute?: false,
      allow_nil?: true

    belongs_to :resolved_in_release, Alplus.Observe.Release,
      source_attribute: :resolved_in_release_id,
      define_attribute?: false,
      allow_nil?: true

    belongs_to :assignee, Alplus.Accounts.User,
      source_attribute: :assignee_id,
      define_attribute?: false,
      allow_nil?: true
  end
end
