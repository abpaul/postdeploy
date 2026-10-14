defmodule Alplus.Sources.Source do
  @moduledoc """
  A named, environment-scoped container for one product's telemetry in one
  project (`docs/adr/0001-unified-telemetry-sources.md`). One active Source
  per `(project, type, environment)` for `:observe`, `:monitor`, and
  `:changelog`; a
  `:measure` Source is a first-class site and an `:analytics` Source is a
  first-class application, so a project may hold several of either,
  including two sharing one environment (issue #34 Model A, ADR 0007).

  Each Source auto-mints its own credential on `:create`
  (`Alplus.Sources.Source.Changes.MintCredential`):

    * `:observe` — a secret ingest key. Only the SHA-256 hash and an
      8-character prefix are stored; the plaintext is returned once via
      the `:secret` action metadata.
    * `:measure` — a public token stored in the clear, for `GET /m.js`
      snippets.
    * `:monitor` — pull-based, no ingest credential.
    * `:changelog` — an agent credential for draft changelog entries only.
    * `:analytics` — a write-only product analytics key (`pda_*`). It is
      published inside mobile and browser clients, so it authorizes
      `POST /v1/events` and nothing else: no analytics read, no project
      configuration, no other pillar (ADR 0007).

  Environment stays server-trusted (ARCHITECTURE.md §4/§8): Observe ingest
  resolves the Source from its secret ingest key
  (`authenticate_observe/1`), product analytics ingest resolves it from the
  analytics write key (`authenticate_analytics/1`), and Measure ingest
  resolves the Source from
  its public Measure token (`resolve_measure/1`); all three treat
  `source.environment` as authoritative, never a client-supplied value.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Sources,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "sources"
    repo Alplus.Repo

    identity_wheres_to_sql unique_source_per_project_type_environment:
                             "status = 'active' AND type NOT IN ('measure', 'analytics')",
                           unique_secret_prefix: "secret_prefix IS NOT NULL",
                           unique_measure_token: "measure_token IS NOT NULL"

    custom_statements do
      statement :sources_checks do
        up """
        ALTER TABLE sources
          ADD CONSTRAINT sources_type_check CHECK (type IN ('monitor', 'observe', 'measure', 'changelog', 'analytics')),
          ADD CONSTRAINT sources_status_check CHECK (status IN ('active', 'revoked')),
          ADD CONSTRAINT sources_name_check CHECK (octet_length(btrim(name)) > 0 AND octet_length(name) <= 120),
          ADD CONSTRAINT sources_environment_check CHECK (octet_length(btrim(environment)) > 0 AND octet_length(environment) <= 64),
          ADD CONSTRAINT sources_hostname_check CHECK (
            hostname IS NULL OR (octet_length(btrim(hostname)) BETWEEN 1 AND 255 AND hostname !~ '[[:space:]/:]')
          ),
          ADD CONSTRAINT sources_secret_hash_format_check CHECK (secret_hash IS NULL OR secret_hash ~ '^[0-9a-f]{64}$'),
          ADD CONSTRAINT sources_secret_prefix_length_check CHECK (secret_prefix IS NULL OR octet_length(secret_prefix) BETWEEN 1 AND 16),
          ADD CONSTRAINT sources_previous_secret_hash_format_check CHECK (previous_secret_hash IS NULL OR previous_secret_hash ~ '^[0-9a-f]{64}$'),
          ADD CONSTRAINT sources_previous_secret_prefix_length_check CHECK (previous_secret_prefix IS NULL OR octet_length(previous_secret_prefix) BETWEEN 1 AND 16),
          ADD CONSTRAINT sources_grace_after_creation_check CHECK (secret_grace_expires_at IS NULL OR secret_grace_expires_at > inserted_at),
          ADD CONSTRAINT sources_measure_token_length_check CHECK (measure_token IS NULL OR octet_length(measure_token) <= 80),
          ADD CONSTRAINT sources_credential_by_type_check CHECK (
            (type IN ('observe', 'changelog', 'analytics') AND secret_hash IS NOT NULL AND secret_prefix IS NOT NULL AND measure_token IS NULL) OR
            (type = 'measure' AND measure_token IS NOT NULL AND secret_hash IS NULL AND secret_prefix IS NULL) OR
            (type = 'monitor' AND secret_hash IS NULL AND secret_prefix IS NULL AND measure_token IS NULL)
          )
        """

        down """
        ALTER TABLE sources
          DROP CONSTRAINT sources_type_check,
          DROP CONSTRAINT sources_status_check,
          DROP CONSTRAINT sources_name_check,
          DROP CONSTRAINT sources_environment_check,
          DROP CONSTRAINT sources_hostname_check,
          DROP CONSTRAINT sources_secret_hash_format_check,
          DROP CONSTRAINT sources_secret_prefix_length_check,
          DROP CONSTRAINT sources_previous_secret_hash_format_check,
          DROP CONSTRAINT sources_previous_secret_prefix_length_check,
          DROP CONSTRAINT sources_grace_after_creation_check,
          DROP CONSTRAINT sources_measure_token_length_check,
          DROP CONSTRAINT sources_credential_by_type_check
        """
      end
    end

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    # Repeats the tenant predicate at the query itself (ARCHITECTURE.md §4),
    # not only in the policy: mirrors `Alplus.Observe.Issue.list_for_project`.
    read :list_for_project do
      argument :project_id, :string, allow_nil?: false
      filter expr(org_id == ^actor(:org_id) and project_id == ^arg(:project_id))
    end

    # One bounded source read feeds both Observe and Measure signals on the
    # organization Projects index. It is restricted to the current org and a
    # caller-supplied project set; it is not an org-wide source directory.
    read :list_for_projects do
      argument :project_ids, {:array, :string}, allow_nil?: false
      filter expr(org_id == ^actor(:org_id) and project_id in ^arg(:project_ids))
    end

    read :exists_for_projects do
      argument :project_ids, {:array, :string}, allow_nil?: false
      filter expr(org_id == ^actor(:org_id) and project_id in ^arg(:project_ids))
    end

    # System-only lookup used by `authenticate_observe/1` below, before any
    # actor exists. No policy grants this to an actor; possession of the
    # raw secret is the authorization proof.
    read :get_by_secret_prefix do
      get? true
      argument :prefix, :string, allow_nil?: false
      filter expr(secret_prefix == ^arg(:prefix) or previous_secret_prefix == ^arg(:prefix))
    end

    # System-only lookup used by `resolve_measure/1`, before any actor
    # exists. The Measure token is public (ADR 0001), so unlike
    # `get_by_secret_prefix` this is not a possession-proves-authorization
    # secret lookup — `resolve_measure/1` still requires `type: :measure`
    # and `status: :active` before trusting the result.
    read :get_by_measure_token do
      get? true
      argument :token, :string, allow_nil?: false
      filter expr(measure_token == ^arg(:token))
    end

    read :read_measure_share do
      get? true

      filter expr(
               id == ^actor(:source_id) and org_id == ^actor(:org_id) and
                 project_id == ^actor(:project_id) and type == :measure and status == :active
             )
    end

    # Only the fields the public Measure dashboard needs. Credentials,
    # hostname, and the display name are never selected here.
    read :read_public_homepage_measure_source do
      get? true
      argument :source_id, :string, allow_nil?: false

      filter expr(
               id == ^arg(:source_id) and org_id == ^actor(:org_id) and
                 project_id == ^actor(:project_id) and type == :measure and status == :active and
                 environment == "production"
             )

      prepare build(select: [:id, :org_id, :project_id, :environment])
    end

    read :list_public_homepage_measure_sources do
      filter expr(
               org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                 type == :measure and status == :active and environment == "production"
             )

      prepare build(select: [:id, :environment], sort: [name: :asc, id: :asc], limit: 5)
    end

    create :create do
      accept [:org_id, :project_id, :type, :environment, :name, :hostname]

      # Reject a project_id that belongs to a different org before minting
      # any credential (AGENTS.md rule 2, ARCHITECTURE.md §4).
      validate Alplus.Sources.Source.Validations.ProjectInOrg

      change Alplus.Sources.Source.Changes.MintCredential

      metadata :secret, :string, allow_nil?: true

      change {Alplus.Audit.Change,
              action: "source.create", subject_type: "source", project_id_attribute: :project_id}
    end

    update :rotate do
      accept []
      require_atomic? false

      argument :grace_period_seconds, :integer do
        allow_nil? false
        default 86_400
        constraints min: 0, max: 604_800
      end

      validate Alplus.Sources.Source.Validations.RotatableType
      # A revoked Source must not mint a fresh, unusable credential.
      validate attribute_equals(:status, :active)
      change Alplus.Sources.Source.Changes.RotateCredential

      metadata :secret, :string, allow_nil?: true

      change {Alplus.Audit.Change,
              action: "source.rotate", subject_type: "source", project_id_attribute: :project_id}
    end

    # The display name is editable on its own. A rename never touches the
    # credential, the type, or the server-trusted environment.
    update :rename do
      accept [:name]
      require_atomic? false

      change {Alplus.Audit.Change,
              action: "source.rename", subject_type: "source", project_id_attribute: :project_id}
    end

    update :configure_hostname do
      accept [:hostname]
      require_atomic? false
      validate attribute_equals(:type, :measure)
      change Alplus.Sources.Source.Changes.NormalizeHostname

      change {Alplus.Audit.Change,
              action: "source.configure_hostname",
              subject_type: "source",
              project_id_attribute: :project_id}
    end

    update :revoke do
      accept []
      require_atomic? false
      change set_attribute(:status, :revoked)

      change {Alplus.Audit.Change,
              action: "source.revoke", subject_type: "source", project_id_attribute: :project_id}
    end

    destroy :destroy do
      require_atomic? false

      change {Alplus.Audit.Change,
              action: "source.destroy", subject_type: "source", project_id_attribute: :project_id}
    end
  end

  # Scope every action by org AND project, mirroring Alplus.Monitoring.Monitor
  # (AGENTS.md rule 2). A read failure filters the row out, so a Source in a
  # sibling project of the same org is a 404, never a 403, and can never be
  # rotated or revoked through the wrong project's URL.
  policies do
    policy action([:read, :list_for_project]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action([:list_for_projects, :exists_for_projects]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action(:read_public_homepage_measure_source) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       type == :measure and status == :active and environment == "production"
                   )
    end

    policy action(:list_public_homepage_measure_sources) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       type == :measure and status == :active and environment == "production"
                   )
    end

    policy action(:read_measure_share) do
      authorize_if expr(
                     id == ^actor(:source_id) and org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and type == :measure and
                       status == :active
                   )
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:user_id) and role in ["owner", "admin"]
                       )
                   )
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "source"
      public? true
      writable? false
      primary_key? true
      allow_nil? false
      default fn -> Alplus.Id.generate("source") end
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
      allow_nil? false
      writable? true
    end

    attribute :type, :atom do
      constraints one_of: [:monitor, :observe, :measure, :changelog, :analytics]
      allow_nil? false
      public? true
      writable? true
    end

    attribute :environment, :string do
      allow_nil? false
      public? true
      constraints max_length: 64
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 120
    end

    # A display name is editable. Keep the represented origin separately so
    # the dashboard can resolve the source to its project-domain row.
    attribute :hostname, :string do
      allow_nil? true
      public? true
      writable? true
      constraints max_length: 255
    end

    attribute :status, :atom do
      constraints one_of: [:active, :revoked]
      allow_nil? false
      default :active
      public? true
      writable? false
    end

    attribute :secret_hash, :string do
      allow_nil? true
      # Private on purpose: no read action or LiveView may serialize it.
      public? false
      writable? false
      sensitive? true
    end

    attribute :secret_prefix, :string do
      allow_nil? true
      public? true
      writable? false
      constraints max_length: 16
    end

    attribute :previous_secret_hash, :string do
      allow_nil? true
      public? false
      writable? false
      sensitive? true
    end

    # Kept so a secret issued before the last rotation can still be found
    # during its grace window. Not a secret, same as `secret_prefix`.
    attribute :previous_secret_prefix, :string do
      allow_nil? true
      public? true
      writable? false
      constraints max_length: 16
    end

    attribute :secret_grace_expires_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      writable? false
    end

    # The Measure credential: a public token, stored in the clear
    # (ADR 0001). Not `sensitive?`, unlike the Observe secret hash above.
    attribute :measure_token, :string do
      allow_nil? true
      public? true
      writable? false
      constraints max_length: 80
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

    belongs_to :project, Alplus.Projects.Project do
      source_attribute :project_id
      define_attribute? false
      allow_nil? false
    end
  end

  identities do
    # One Source per product per environment (ADR 0001, decision 1),
    # scoped to non-revoked rows so a revoked Source's slot can be
    # reused by a fresh one. `:measure` is excluded (issue #34, Model A):
    # a Measure Source is a first-class site, and a project may hold
    # several active measure sources, including two in the same
    # environment. `:analytics` is excluded for the same reason (ADR 0007):
    # one project ships an iOS app, an Android app, and a web app, and each
    # needs a key it can rotate or revoke without stopping the others.
    # Observe and monitor keep the original one-per-
    # (project, type, environment) rule unchanged.
    identity :unique_source_per_project_type_environment, [:project_id, :type, :environment],
      where: expr(status == :active and type not in [:measure, :analytics])

    # The unique index goes on the prefix, never on the hash
    # (ARCHITECTURE.md §5 rule 5: never index a secret column).
    identity :unique_secret_prefix, [:secret_prefix], where: expr(not is_nil(secret_prefix))

    identity :unique_measure_token, [:measure_token], where: expr(not is_nil(measure_token))
  end

  @doc """
  Authenticates a raw `obs_*` secret against an `:observe` Source. Returns
  the live Source (not revoked, and either matching the current hash or
  matching the previous hash within its grace window) or
  `{:error, :not_found}` for anything else — never distinguishes "wrong
  secret" from "unknown secret" (ARCHITECTURE.md §14 rule 4).
  """
  @spec authenticate_observe(String.t()) :: {:ok, t()} | {:error, :not_found}
  def authenticate_observe(secret), do: authenticate_secret(secret, :observe)

  @doc """
  Authenticates a raw `pda_*` write key against an `:analytics` Source.

  The key is published inside customer applications, so it proves one thing
  only: the holder may write product analytics events into this Source's
  project. It never resolves an Observe, Measure, Monitor or Changelog
  Source, so a leaked key reaches no other pillar. Same failure contract as
  `authenticate_observe/1`: one `{:error, :not_found}` for a wrong, unknown,
  revoked, or wrong-type key.
  """
  @spec authenticate_analytics(String.t()) :: {:ok, t()} | {:error, :not_found}
  def authenticate_analytics(secret), do: authenticate_secret(secret, :analytics)

  defp authenticate_secret(secret, expected_type) when is_binary(secret) do
    hash = Alplus.Security.BearerToken.hash(secret)
    prefix = Alplus.Security.BearerToken.short_prefix(secret)

    with true <- is_binary(prefix),
         {:ok, %__MODULE__{type: ^expected_type} = source} <-
           __MODULE__
           |> Ash.Query.for_read(:get_by_secret_prefix, %{prefix: prefix}, authorize?: false)
           |> Ash.read_one(authorize?: false),
         true <- valid_for?(source, hash) do
      {:ok, source}
    else
      _ -> {:error, :not_found}
    end
  end

  defp authenticate_secret(_secret, _expected_type), do: {:error, :not_found}

  @doc """
  Resolves a public `msr_*` Measure token to its active `:measure` Source.
  The token is public (embedded in a served browser snippet, ADR 0001
  decision 8), so unlike `authenticate_observe/1` this is not a secret
  lookup — it only maps token to Source, project, org, and the
  server-trusted `environment`.

  Returns `{:error, :not_found}` for an unknown token, a revoked Source,
  or a Source of the wrong type — never distinguishes these
  (ARCHITECTURE.md §14 rule 4), so the ingest controller's rejection stays
  wire-identical whether a token never existed or was revoked.
  """
  @spec resolve_measure(String.t()) :: {:ok, t()} | {:error, :not_found}
  def resolve_measure(token) when is_binary(token) do
    case __MODULE__
         |> Ash.Query.for_read(:get_by_measure_token, %{token: token}, authorize?: false)
         |> Ash.read_one(authorize?: false) do
      {:ok, %__MODULE__{type: :measure, status: :active} = source} -> {:ok, source}
      _ -> {:error, :not_found}
    end
  end

  def resolve_measure(_token), do: {:error, :not_found}

  defp valid_for?(%__MODULE__{status: :revoked}, _hash), do: false

  defp valid_for?(%__MODULE__{} = source, hash) do
    cond do
      Alplus.Security.BearerToken.matches?(source.secret_hash, hash) ->
        true

      Alplus.Security.BearerToken.matches?(source.previous_secret_hash, hash) ->
        not is_nil(source.secret_grace_expires_at) and
          DateTime.compare(DateTime.utc_now(), source.secret_grace_expires_at) == :lt

      true ->
        false
    end
  end
end
