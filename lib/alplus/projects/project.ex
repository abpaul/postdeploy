defmodule Alplus.Projects.Project do
  @moduledoc """
  A project inside an org (ARCHITECTURE.md §3, §5, §13). Soft-deleted via
  `AshArchival` (14-day grace period, enforced later by a daily purge job —
  not built in this slice).
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Projects,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshArchival.Resource]

  postgres do
    table "projects"
    repo Alplus.Repo

    identity_wheres_to_sql unique_slug_per_org: "archived_at IS NULL",
                           unique_public_token: "archived_at IS NULL"

    # ARCHITECTURE.md §5 rule 4: every free-text column carries an
    # octet_length cap in the database, not only in the changeset.
    custom_statements do
      statement :name_length_check do
        up "ALTER TABLE projects ADD CONSTRAINT projects_name_length_check CHECK (octet_length(name) <= 200)"
        down "ALTER TABLE projects DROP CONSTRAINT projects_name_length_check"
      end

      statement :slug_length_check do
        up "ALTER TABLE projects ADD CONSTRAINT projects_slug_length_check CHECK (octet_length(slug) <= 63)"
        down "ALTER TABLE projects DROP CONSTRAINT projects_slug_length_check"
      end

      statement :public_token_length_check do
        up "ALTER TABLE projects ADD CONSTRAINT projects_public_token_length_check CHECK (public_token IS NULL OR octet_length(public_token) = 16)"
        down "ALTER TABLE projects DROP CONSTRAINT projects_public_token_length_check"
      end
    end

    references do
      reference :organization, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    # Repeats the tenant predicate at the query itself (ARCHITECTURE.md §4)
    # instead of relying on the read policy alone: the policy only proves
    # the actor belongs to *some* org that owns the project, which is not
    # enough to scope a project list to one specific org when an actor
    # holds memberships in several.
    read :list_for_org do
      argument :org_id, :string, allow_nil?: false
      filter expr(org_id == ^arg(:org_id))
    end

    read :list_for_orgs do
      argument :org_ids, {:array, :string}, allow_nil?: false
      filter expr(org_id in ^arg(:org_ids))
    end

    create :create do
      # Keep this legacy input during the expand phase. Console forms no
      # longer expose it; the later contract migration can remove it after
      # all callers use `public_token` URLs.
      accept [:org_id, :name, :slug]

      change {Alplus.Billing.Changes.EnforceCapacity, metric: :projects}

      change {Alplus.Audit.Change,
              action: "project.create", subject_type: "project", project_id_attribute: :id}
    end

    update :update do
      accept [:name, :slug]
      require_atomic? false

      # Entitlement gate: an inactive organization (expired trial, lapsed
      # subscription) may not edit projects. Reads stay open.
      change fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn changeset ->
          case Alplus.Billing.Access.check(Ash.Changeset.get_attribute(changeset, :org_id)) do
            {:ok, _access} -> changeset
            {:error, %{message: message}} -> Ash.Changeset.add_error(changeset, message: message)
          end
        end)
      end

      change {Alplus.Audit.Change,
              action: "project.update", subject_type: "project", project_id_attribute: :id}
    end

    # Persisted, one-time "product went live" milestone (issue #33). Sets
    # the timestamp only the first time it is called for this project; a
    # later call is a no-op so a race between two viewers never overwrites
    # the original activation moment. Any project member may trigger this
    # (not only owner/admin) because it fires as a side effect of viewing
    # the dashboard, not a deliberate mutation.
    update :activate_measure do
      accept []
      require_atomic? false

      change fn changeset, _context ->
        if is_nil(changeset.data.measure_activated_at) do
          Ash.Changeset.force_change_attribute(
            changeset,
            :measure_activated_at,
            DateTime.utc_now()
          )
        else
          changeset
        end
      end
    end

    update :activate_observe do
      accept []
      require_atomic? false

      change fn changeset, _context ->
        if is_nil(changeset.data.observe_activated_at) do
          Ash.Changeset.force_change_attribute(
            changeset,
            :observe_activated_at,
            DateTime.utc_now()
          )
        else
          changeset
        end
      end
    end

    destroy :archive do
      primary? true
      require_atomic? false

      change {Alplus.Audit.Change,
              action: "project.archive", subject_type: "project", project_id_attribute: :id}
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(exists(organization.memberships, user_id == ^actor(:user_id)))
    end

    policy action_type(:create) do
      authorize_if expr(
                     exists(
                       organization.memberships,
                       user_id == ^actor(:user_id) and role in ["owner", "admin"]
                     )
                   )
    end

    # `action_type([:update, :destroy])` would also match :activate_measure
    # and :activate_observe (they are :update actions), which would AND an
    # owner/admin requirement onto them (Ash ANDs every applicable policy).
    # Naming the mutating actions explicitly here keeps this policy from
    # applying to the activation actions at all.
    policy action([:update, :archive]) do
      authorize_if expr(
                     exists(
                       organization.memberships,
                       user_id == ^actor(:user_id) and role in ["owner", "admin"]
                     )
                   )
    end

    # The activation milestone fires as a side effect of any member viewing
    # the dashboard once the product goes live, so it needs read-level
    # access, not the owner/admin bar the rest of :update carries.
    policy action([:activate_measure, :activate_observe]) do
      authorize_if expr(exists(organization.memberships, user_id == ^actor(:user_id)))
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "project"
      public? true
      writable? false
      primary_key? true
      allow_nil? false
      default fn -> Alplus.Id.generate("project") end
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 200
    end

    attribute :slug, :string do
      allow_nil? true
      public? true

      constraints max_length: 63,
                  match: ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/
    end

    attribute :public_token, :string do
      allow_nil? true
      public? true
      writable? false
      default &Alplus.PublicToken.generate/0

      constraints min_length: 16,
                  max_length: 16,
                  match: ~r/\A[0-9A-Za-z]{16}\z/
    end

    attribute :org_id, Alplus.Id do
      constraints prefix: "organization"
      public? true
      allow_nil? false
      writable? true
    end

    # One-time "product went live" milestone (issue #33), set by
    # :activate_measure / :activate_observe the first time each product
    # has data for this project. `nil` means not yet activated; a member
    # viewing the dashboard on that transition is the only writer.
    attribute :measure_activated_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      writable? false
    end

    attribute :observe_activated_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      writable? false
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :organization, Alplus.Orgs.Organization do
      source_attribute :org_id
      define_attribute? false
      allow_nil? false
    end
  end

  identities do
    identity :unique_slug_per_org, [:org_id, :slug], where: expr(is_nil(archived_at))
    identity :unique_public_token, [:public_token], where: expr(is_nil(archived_at))
  end
end
