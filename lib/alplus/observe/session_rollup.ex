defmodule Alplus.Observe.SessionRollup do
  @moduledoc """
  Aggregate-only crash-free session rollups (issue #12): sessions / errored
  / crashed counts per org + project + environment + release + UTC day
  window. ARCHITECTURE.md §8 decision #4: never a raw per-session row --
  `Alplus.Observe.SessionRollupWriter` (a direct PostgreSQL writer, the same
  "optimized write" pattern `Alplus.Observe.EventWriter` and
  `Alplus.Measure.Rollups` already use for a hot ingest path) is the only
  writer. This resource exists for the durable schema and the read side
  (`Alplus.Observe.SessionHealth`, the Observe Releases UI) -- it carries no
  create/update/destroy action, matching that there is no actor-triggered
  write path.

  Phase A of the Source-scoping rework (issue #46 follow-up, see
  `docs/observe-source-id-phase-b.md`): `source_id` is stamped by
  `Alplus.Observe.SessionRollupWriter` and reads are scoped by it
  (`Alplus.Observe.SessionHealth.crash_free/3`), but the uniqueness
  constraint and the writer's `ON CONFLICT` target stay on `(org_id,
  project_id, environment, release, window_start)` for this deploy, for the
  same Kamal-cutover reason documented on `Alplus.Observe.Issue`.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Observe,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "observe_session_rollups"
    repo Alplus.Repo

    custom_indexes do
      # Phase A keeps this unique index on the old `environment` key
      # (docs/observe-source-id-phase-b.md). Phase B swaps it for a
      # `source_id`-keyed unique index in a later, separate deploy.
      index [:org_id, :project_id, :environment, :release, :window_start],
        unique: true,
        nulls_distinct: false,
        name: "observe_session_rollups_scope_window_index"

      index [:org_id, :project_id, :environment, :release],
        name: "observe_session_rollups_scope_index"

      # Read-path index only; Alplus.Observe.SessionHealth.crash_free/3
      # filters by source_id. Not unique; the ingest writer's conflict
      # target stays environment-keyed until Phase B.
      index [:org_id, :project_id, :source_id, :release, :window_start],
        name: "observe_session_rollups_source_id_index"
    end

    custom_statements do
      statement :session_rollup_constraints do
        up """
        ALTER TABLE observe_session_rollups
          ADD CONSTRAINT observe_session_rollups_counts_check CHECK (
            sessions_count >= 0 AND errored_count >= 0 AND crashed_count >= 0 AND
            errored_count + crashed_count <= sessions_count
          ),
          ADD CONSTRAINT observe_session_rollups_environment_check CHECK (environment IS NULL OR octet_length(environment) <= 64),
          ADD CONSTRAINT observe_session_rollups_release_check CHECK (release IS NULL OR octet_length(release) <= 256)
        """

        down """
        ALTER TABLE observe_session_rollups
          DROP CONSTRAINT observe_session_rollups_counts_check,
          DROP CONSTRAINT observe_session_rollups_environment_check,
          DROP CONSTRAINT observe_session_rollups_release_check
        """
      end
    end

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :source, on_delete: :nilify
    end
  end

  actions do
    defaults [:read]

    # Scoped by source_id (issue #46 follow-up finding 2), not by the bare
    # `environment` string: two Sources sharing one environment must never
    # blend their crash-free numbers on one release.
    read :list_for_release do
      argument :project_id, :string, allow_nil?: false
      argument :source_id, :string, allow_nil?: false
      argument :release, :string, allow_nil?: false

      filter expr(
               org_id == ^actor(:org_id) and project_id == ^arg(:project_id) and
                 release == ^arg(:release) and source_id == ^arg(:source_id)
             )
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "ssr"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:session_rollup) end
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
    # could not attribute to any Source.
    attribute :source_id, Alplus.Id,
      constraints: [prefix: "source"],
      allow_nil?: true,
      public?: true

    attribute :environment, :string, allow_nil?: true, public?: true
    attribute :release, :string, allow_nil?: true, public?: true
    attribute :window_start, :date, allow_nil?: false, public?: true
    attribute :sessions_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :errored_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :crashed_count, :integer, allow_nil?: false, default: 0, public?: true
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
  end
end
