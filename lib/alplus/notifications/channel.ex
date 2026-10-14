defmodule Alplus.Notifications.Channel do
  @moduledoc """
  A tenant notification destination.

  `config` is an AshCloak attribute. AshCloak stores only the ciphertext in
  `encrypted_config`; it never exposes that column through this resource.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Notifications,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak]

  postgres do
    table "notification_channels"
    repo Alplus.Repo

    custom_indexes do
      index [:org_id]

      index [:org_id],
        unique: true,
        where: "is_default",
        name: "notification_channels_one_default_index"
    end

    custom_statements do
      statement :channel_constraints do
        up """
        ALTER TABLE notification_channels
          ADD CONSTRAINT notification_channels_type_check CHECK (type IN ('email', 'slack', 'discord', 'webhook', 'telegram')),
          ADD CONSTRAINT notification_channels_name_check CHECK (octet_length(btrim(name)) BETWEEN 1 AND 120),
          ADD CONSTRAINT notification_channels_encrypted_config_check CHECK (octet_length(encrypted_config) <= 16384)
        """

        down """
        ALTER TABLE notification_channels
          DROP CONSTRAINT notification_channels_type_check,
          DROP CONSTRAINT notification_channels_name_check,
          DROP CONSTRAINT notification_channels_encrypted_config_check
        """
      end
    end

    references do
      reference :organization, on_delete: :delete
    end
  end

  cloak do
    vault(Alplus.NotificationsVault)
    attributes([:config])
  end

  actions do
    defaults [:read]

    read :list_for_org do
      argument :org_id, :string, allow_nil?: false
      filter expr(org_id == ^actor(:org_id) and org_id == ^arg(:org_id))
    end

    create :create do
      accept [:org_id, :type, :name, :config, :is_default]

      validate fn changeset, _context ->
        type = Ash.Changeset.get_attribute(changeset, :type)

        case validate_config_argument(changeset, type) do
          :ok ->
            :ok

          {:error, :invalid_config} ->
            {:error, field: :config, message: "Invalid channel configuration"}
        end
      end

      change fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn changeset ->
          org_id = Ash.Changeset.get_attribute(changeset, :org_id)
          type = Ash.Changeset.get_attribute(changeset, :type)

          case Alplus.Billing.Access.allow_notification_channel(org_id, type) do
            :ok ->
              changeset

            {:error, %{message: message}} ->
              Ash.Changeset.add_error(changeset, message: message)
          end
        end)
      end
    end

    update :update do
      accept [:name, :config, :is_default]
      require_atomic? false

      validate fn changeset, _context ->
        type =
          Ash.Changeset.get_attribute(changeset, :type) ||
            Ash.Changeset.get_data(changeset, :type)

        case validate_config_argument(changeset, type) do
          :ok ->
            :ok

          {:error, :invalid_config} ->
            {:error, field: :config, message: "Invalid channel configuration"}
        end
      end

      # Entitlement gate: an inactive organization (expired trial, lapsed
      # subscription) may not edit channels. Reads stay open.
      change fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn changeset ->
          org_id = Ash.Changeset.get_attribute(changeset, :org_id)

          case Alplus.Billing.Access.check(org_id) do
            {:ok, _access} ->
              changeset

            {:error, %{message: message}} ->
              Ash.Changeset.add_error(changeset, message: message)
          end
        end)
      end
    end

    destroy :destroy do
      require_atomic? false
    end
  end

  defp validate_config_argument(changeset, type) do
    case Ash.Changeset.fetch_argument(changeset, :config) do
      {:ok, config} -> Alplus.Notifications.ChannelConfig.validate(type, config)
      :error -> :ok
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:user_id) and role in ["owner", "admin"]
                       )
                   )
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "chan"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:notification_channel) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :type, :string, allow_nil?: false, public?: true

    attribute :name, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: 120]

    # AshCloak replaces this declaration with a sensitive, private
    # `encrypted_config` attribute and a non-filterable `config` calculation.
    attribute :config, :map, allow_nil?: false, public?: false
    attribute :is_default, :boolean, allow_nil?: false, default: false, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :organization, Alplus.Orgs.Organization,
      source_attribute: :org_id,
      define_attribute?: false,
      allow_nil?: false
  end
end
