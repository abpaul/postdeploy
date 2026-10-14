defmodule Alplus.Measure.DashboardShare do
  @moduledoc "A rotatable, panel-scoped public view of one Measure site."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Measure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Alplus.Measure.ShareActor

  @panels [:headline_cards, :chart, :pages, :sources, :events, :countries, :browsers]
  @default_panels [:headline_cards, :chart, :pages]

  postgres do
    table "measure_dashboard_shares"
    repo Alplus.Repo

    migration_defaults panels: "fragment(\"ARRAY['headline_cards','chart','pages']::text[]\")"

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :source, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    read :for_source do
      get? true
      argument :source_id, :string, allow_nil?: false

      filter expr(
               org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                 source_id == ^arg(:source_id)
             )
    end

    read :get_by_token_prefix do
      get? true
      argument :prefix, :string, allow_nil?: false
      filter expr(token_prefix == ^arg(:prefix))
    end

    read :read_public do
      get? true

      filter expr(
               id == ^actor(:share_id) and org_id == ^actor(:org_id) and
                 project_id == ^actor(:project_id) and source_id == ^actor(:source_id)
             )
    end

    # The homepage may only load a single explicitly public dashboard from
    # the project already resolved as the vendor. The caller is the
    # Changelog public actor returned by `resolve_vendor/0`; the action's
    # tenant filter never accepts a project identifier from a request.
    read :public_homepage_for_vendor do
      get? true

      filter expr(
               org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                 :headline_cards in panels and :chart in panels and :pages in panels
             )

      prepare build(
                select: [:id, :org_id, :project_id, :source_id, :panels, :updated_at],
                sort: [updated_at: :desc, id: :desc],
                limit: 1
              )
    end

    action :public_panel, :map do
      argument :share_id, :string, allow_nil?: false
      argument :org_id, :string, allow_nil?: false
      argument :project_id, :string, allow_nil?: false
      argument :source_id, :string, allow_nil?: false
      argument :environment, :string, allow_nil?: false

      argument :dimension, :atom,
        allow_nil?: false,
        constraints: [one_of: [:path, :referrer, :event, :country, :browser]]

      argument :since, :date, allow_nil?: false
      argument :until, :date, allow_nil?: false
      argument :page, :integer, allow_nil?: false, constraints: [min: 1, max: 25]

      run Alplus.Measure.DashboardShare.Actions.PublicPanel
    end

    create :create do
      primary? true
      accept [:org_id, :project_id, :source_id, :panels]
      validate Alplus.Measure.DashboardShare.Validations.SourceInScope
      change Alplus.Measure.DashboardShare.Changes.MintToken

      change {Alplus.Audit.Change,
              action: "measure_share.create",
              subject_type: "measure_dashboard_share",
              project_id_attribute: :project_id}
    end

    update :update_panels do
      accept [:panels]
      require_atomic? false

      change {Alplus.Audit.Change,
              action: "measure_share.update",
              subject_type: "measure_dashboard_share",
              project_id_attribute: :project_id}
    end

    update :rotate do
      accept []
      require_atomic? false
      change Alplus.Measure.DashboardShare.Changes.MintToken

      change {Alplus.Audit.Change,
              action: "measure_share.rotate",
              subject_type: "measure_dashboard_share",
              project_id_attribute: :project_id}
    end

    destroy :revoke do
      require_atomic? false

      change {Alplus.Audit.Change,
              action: "measure_share.revoke",
              subject_type: "measure_dashboard_share",
              project_id_attribute: :project_id}
    end
  end

  policies do
    policy action([:read, :for_source]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    # `public_homepage_for_vendor` is only reached with the public actor
    # returned by Changelog.Public.resolve_vendor/0. Keeping the same
    # organization/project predicate here prevents an arbitrary public actor
    # from selecting a dashboard in another tenant.
    policy action(:public_homepage_for_vendor) do
      authorize_if expr(org_id == ^actor(:org_id) and project_id == ^actor(:project_id))
    end

    policy action(:read_public) do
      authorize_if expr(
                     id == ^actor(:share_id) and org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and source_id == ^actor(:source_id)
                   )
    end

    policy action(:public_panel) do
      authorize_if Alplus.Measure.DashboardShare.Checks.PublicPanelAllowed
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:user_id) and role in ["owner", "admin"]
                       )
                   )
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "mshare"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:measure_dashboard_share) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :project_id, Alplus.Id,
      constraints: [prefix: "project"],
      allow_nil?: false,
      public?: true

    attribute :source_id, Alplus.Id,
      constraints: [prefix: "source"],
      allow_nil?: false,
      public?: true

    attribute :token_hash, :string,
      allow_nil?: false,
      writable?: false,
      sensitive?: true,
      public?: false,
      constraints: [min_length: 64, max_length: 64]

    attribute :token_prefix, :string,
      allow_nil?: false,
      writable?: false,
      public?: true,
      constraints: [min_length: 8, max_length: 8]

    attribute :panels, {:array, :atom},
      allow_nil?: false,
      public?: true,
      default: @default_panels,
      constraints: [min_length: 1, max_length: 7, items: [one_of: @panels]]

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
      allow_nil?: false
  end

  identities do
    identity :one_share_per_source, [:source_id]
    identity :unique_token_prefix, [:token_prefix]
  end

  @doc "Resolves one raw share token through a token-scoped Ash read policy."
  def resolve(token) when is_binary(token) do
    hash = Alplus.Security.BearerToken.hash(token)
    prefix = Alplus.Security.BearerToken.short_prefix(token)

    with true <- is_binary(prefix),
         {:ok, %__MODULE__{} = candidate} <- by_prefix(prefix),
         true <- Alplus.Security.BearerToken.matches?(candidate.token_hash, hash),
         {:ok, _access} <- Alplus.Billing.Access.check(candidate.org_id),
         {:ok, %{type: :measure, status: :active} = source} <-
           Ash.get(Alplus.Sources.Source, candidate.source_id, authorize?: false),
         actor <- public_actor(candidate, source),
         {:ok, %__MODULE__{} = share} <-
           Ash.get(__MODULE__, candidate.id, action: :read_public, actor: actor) do
      {:ok, share, actor}
    else
      _other -> {:error, :not_found}
    end
  end

  def resolve(_token), do: {:error, :not_found}

  defp by_prefix(prefix) do
    __MODULE__
    |> Ash.Query.for_read(:get_by_token_prefix, %{prefix: prefix}, authorize?: false)
    |> Ash.read_one(authorize?: false)
  end

  defp public_actor(share, source) do
    %ShareActor{
      share_id: share.id,
      org_id: share.org_id,
      project_id: share.project_id,
      source_id: share.source_id,
      environment: source.environment,
      panels: share.panels
    }
  end
end
