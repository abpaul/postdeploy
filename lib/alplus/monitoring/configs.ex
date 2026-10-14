defmodule Alplus.Monitoring.Configs do
  @moduledoc false

  defmacro __using__(opts) do
    public_select = Keyword.get(opts, :public_schedule_fields, [:interval_seconds])

    quote do
      use Ash.Resource,
        otp_app: :alplus,
        domain: Alplus.Monitoring,
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer]

      attributes do
        attribute :monitor_id, Alplus.Id do
          constraints prefix: "mon"
          primary_key? true
          allow_nil? false
          public? true
        end

        attribute :org_id, Alplus.Id do
          constraints prefix: "organization"
          allow_nil? false
          public? true
        end
      end

      relationships do
        belongs_to :monitor, Alplus.Monitoring.Monitor do
          source_attribute :monitor_id
          define_attribute? false
          allow_nil? false
        end
      end

      actions do
        defaults [:read]

        # The marketing homepage names each monitor's protocol and cadence.
        # Only the schedule fields are selected: never a target, a header, a
        # credential, or any other configuration value.
        read :public_homepage_for_vendor do
          argument :monitor_ids, {:array, :string}, allow_nil?: false

          filter expr(
                   ^ref(:org_id) == ^actor(:org_id) and
                     ^ref(:monitor_id) in ^arg(:monitor_ids) and
                     exists(
                       monitor,
                       ^ref(:project_id) == ^actor(:project_id) and
                         ^ref(:environment) == "production" and
                         ^ref(:status) == "active"
                     )
                 )

          prepare build(select: [:monitor_id | unquote(public_select)], limit: 20)
        end
      end

      policies do
        # A bypass, not a plain policy: the generic read policy below demands an
        # organization membership, and the public homepage actor has no user.
        bypass action(:public_homepage_for_vendor) do
          authorize_if expr(
                         ^ref(:org_id) == ^actor(:org_id) and
                           exists(
                             monitor,
                             ^ref(:project_id) == ^actor(:project_id) and
                               ^ref(:environment) == "production" and
                               ^ref(:status) == "active"
                           )
                       )
        end

        policy action_type(:read) do
          authorize_if expr(
                         ^ref(:org_id) == ^actor(:org_id) and
                           exists(
                             monitor,
                             ^ref(:project_id) == ^actor(:project_id) and
                               exists(
                                 organization.memberships,
                                 ^ref(:user_id) == ^actor(:user_id)
                               )
                           )
                       )
        end

        policy action_type([:create, :update, :destroy]) do
          authorize_if expr(
                         ^ref(:org_id) == ^actor(:org_id) and
                           exists(
                             monitor,
                             ^ref(:project_id) == ^actor(:project_id) and
                               exists(
                                 organization.memberships,
                                 ^ref(:user_id) == ^actor(:user_id) and
                                   ^ref(:role) in ["owner", "admin"]
                               )
                           )
                       )
        end
      end
    end
  end
end
