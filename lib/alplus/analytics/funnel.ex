defmodule Alplus.Analytics.Funnel do
  @moduledoc """
  A saved, ordered product-analytics funnel (ADR 0007).

  A funnel names between two and eight event names in order. Reading it runs
  `Alplus.Analytics.Queries.funnel/2`; this resource only stores the
  definition, so an edit never recomputes anything.

  Agents create and edit funnels through MCP, as they do every other
  project configuration (PRODUCT.md: the console is read-only).
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Analytics,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @max_steps 8
  @min_steps 2

  @doc "The step-count bounds a funnel definition must satisfy."
  @spec step_bounds() :: Range.t()
  def step_bounds, do: @min_steps..@max_steps

  postgres do
    table "product_funnels"
    repo Alplus.Repo

    custom_indexes do
      index [:org_id, :project_id]
    end

    custom_statements do
      statement :product_funnel_checks do
        up """
        ALTER TABLE product_funnels
          ADD CONSTRAINT product_funnels_name_check CHECK (octet_length(btrim(name)) > 0 AND octet_length(name) <= 120),
          ADD CONSTRAINT product_funnels_steps_check CHECK (
            array_length(steps, 1) BETWEEN #{@min_steps} AND #{@max_steps}
          ),
          ADD CONSTRAINT product_funnels_filters_check CHECK (jsonb_typeof(filters) = 'object'),
          ADD CONSTRAINT product_funnels_window_hours_check CHECK (window_hours BETWEEN 1 AND 2160),
          ADD CONSTRAINT product_funnels_breakdown_check CHECK (
            breakdown_property IS NULL OR octet_length(breakdown_property) BETWEEN 1 AND 64
          )
        """

        down """
        ALTER TABLE product_funnels
          DROP CONSTRAINT product_funnels_name_check,
          DROP CONSTRAINT product_funnels_steps_check,
          DROP CONSTRAINT product_funnels_filters_check,
          DROP CONSTRAINT product_funnels_window_hours_check,
          DROP CONSTRAINT product_funnels_breakdown_check
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

    read :list_for_project do
      argument :project_id, :string, allow_nil?: false
      filter expr(org_id == ^actor(:org_id) and project_id == ^arg(:project_id))
      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    create :create do
      primary? true
      accept [:org_id, :project_id, :name, :steps, :window_hours, :filters, :breakdown_property]
      validate Alplus.Analytics.Funnel.Validations.Definition

      change {Alplus.Audit.Change,
              action: "analytics_funnel.create",
              subject_type: "product_funnel",
              project_id_attribute: :project_id}
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:name, :steps, :window_hours, :filters, :breakdown_property]
      validate Alplus.Analytics.Funnel.Validations.Definition

      change {Alplus.Audit.Change,
              action: "analytics_funnel.update",
              subject_type: "product_funnel",
              project_id_attribute: :project_id}
    end

    destroy :destroy do
      primary? true
      require_atomic? false

      change {Alplus.Audit.Change,
              action: "analytics_funnel.destroy",
              subject_type: "product_funnel",
              project_id_attribute: :project_id}
    end
  end

  # Mirrors `Alplus.Measure.Goal`: every action is scoped by org AND project
  # AND live membership, so a funnel in a sibling project is a 404.
  policies do
    policy action_type(:read) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
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
      constraints prefix: "pfun"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:product_funnel) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :project_id, Alplus.Id,
      constraints: [prefix: "project"],
      allow_nil?: false,
      public?: true

    attribute :name, :string, allow_nil?: false, public?: true, constraints: [max_length: 120]

    attribute :steps, {:array, :string}, allow_nil?: false, public?: true

    # The conversion window, measured from each person's first step-one event
    # (spec §60). Seven days suits a product where onboarding spans sessions.
    attribute :window_hours, :integer,
      allow_nil?: false,
      public?: true,
      default: 168,
      constraints: [min: 1, max: 2160]

    # `%{"platform" => "ios"}`: every listed property must equal its value on
    # every step event.
    attribute :filters, :map, allow_nil?: false, public?: true, default: %{}

    attribute :breakdown_property, :string, public?: true, constraints: [max_length: 64]

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
    identity :unique_name_per_project, [:project_id, :name]
  end
end
