defmodule Alplus.Notifications do
  @moduledoc """
  Durable notification routing and delivery state.

  Delivery workers stay in OTP/Oban. This domain owns only tenant-scoped
  configuration, rules, and the idempotent delivery ledger.
  """

  use Ash.Domain, otp_app: :alplus

  require Ash.Query

  alias Alplus.Notifications.{AlertRule, Channel, Delivery}
  alias Alplus.Projects.Project
  alias Alplus.Repo
  alias Alplus.Scope

  @channel_types ~w(email slack discord webhook telegram)
  @max_delivery_history 50

  resources do
    resource Alplus.Notifications.Channel do
      define :get_channel, action: :read, get_by: [:id]
      define :list_channels_for_org, action: :list_for_org, args: [:org_id]
      define :archive_channel, action: :destroy
    end

    resource Alplus.Notifications.AlertRule do
      define :create_alert_rule, action: :create
      define :get_alert_rule, action: :read, get_by: [:id]
      define :list_alert_rules_for_project, action: :list_for_project, args: [:project_id]
      define :update_alert_rule, action: :update
      define :archive_alert_rule, action: :destroy
    end

    resource Alplus.Notifications.Delivery do
      define :get_notification_delivery, action: :read, get_by: [:id]
      define :list_notification_deliveries, action: :read
    end
  end

  @doc """
  Creates a channel inside the plan, scope, and default-selection boundary.

  Returns only the safe presentation. The decrypted config never leaves this
  module.
  """
  @spec create_channel(map(), Scope.t()) :: {:ok, map()} | {:error, term()}
  def create_channel(attrs, %Scope{org_id: org_id} = scope)
      when is_map(attrs) and is_binary(org_id) do
    with :ok <- ensure_scope_attribute(Map.get(attrs, :org_id), org_id),
         {:ok, channel} <-
           with_default_selection(org_id, nil, Map.get(attrs, :is_default, false), fn ->
             Ash.create(Channel, attrs,
               action: :create,
               actor: scope,
               return_notifications?: true
             )
           end) do
      channel_presentation_for_id(channel.id, scope)
    end
  end

  def create_channel(_attrs, _scope), do: {:error, :scope_mismatch}

  @doc """
  Updates a channel inside the plan, scope, and default-selection boundary.

  Accepts a channel id or any map that carries one. Returns only the safe
  presentation.
  """
  @spec update_channel(String.t() | map(), map(), Scope.t()) :: {:ok, map()} | {:error, term()}
  def update_channel(channel_or_id, attrs, %Scope{org_id: org_id} = scope)
      when is_map(attrs) and is_binary(org_id) do
    with {:ok, channel_id} <- entity_id(channel_or_id),
         {:ok, channel} <- fetch_channel_for_mutation(channel_id, scope),
         {:ok, _updated} <-
           with_default_selection(org_id, channel.id, Map.get(attrs, :is_default), fn ->
             Ash.update(channel, attrs,
               action: :update,
               actor: scope,
               return_notifications?: true
             )
           end) do
      channel_presentation_for_id(channel_id, scope)
    end
  end

  def update_channel(_channel_or_id, _attrs, _scope), do: {:error, :scope_mismatch}

  @doc "Destroys a channel after Ash policy evaluation and returns no channel data."
  @spec delete_channel(String.t() | map(), Scope.t()) :: :ok | {:error, term()}
  def delete_channel(channel_or_id, %Scope{org_id: org_id} = scope) when is_binary(org_id) do
    with {:ok, channel_id} <- entity_id(channel_or_id),
         {:ok, channel} <- fetch_channel_for_mutation(channel_id, scope),
         false <- delivery_exists?(scope, channel_id: channel.id),
         {:ok, _deleted} <- Ash.destroy(channel, action: :destroy, actor: scope) do
      :ok
    else
      true -> {:error, :deliveries_exist}
      error -> error
    end
  end

  def delete_channel(_channel_or_id, _scope), do: {:error, :scope_mismatch}

  @doc """
  Returns channel rows safe for a LiveView assign.

  AshCloak decrypts `config` for the query, but this function immediately
  reduces each row to a presentation map. The decrypted map never leaves this
  module and is never kept in a socket assign.
  """
  @spec list_channel_presentations(Scope.t()) ::
          {:ok, [map()]} | {:error, Ash.Error.t() | :scope_mismatch}
  def list_channel_presentations(%Scope{org_id: org_id} = scope) when is_binary(org_id) do
    query =
      Channel
      |> Ash.Query.for_read(:list_for_org, %{org_id: org_id}, actor: scope)
      |> Ash.Query.load(:config)
      |> Ash.Query.sort(is_default: :desc, inserted_at: :desc)

    case Ash.read(query) do
      {:ok, channels} -> {:ok, Enum.map(channels, &channel_presentation/1)}
      {:error, error} -> {:error, error}
    end
  end

  def list_channel_presentations(_scope), do: {:error, :scope_mismatch}

  @doc """
  Lists project rules with a safe channel presentation.

  AlertRule is deliberately project-scoped. The caller supplies the already
  policy-scoped project list, and each query receives a scope carrying that
  project's id. This keeps an org settings page from weakening the resource
  policy with an org-wide read actor.
  """
  @spec list_rule_presentations(Scope.t(), [map()]) ::
          {:ok, [map()]} | {:error, Ash.Error.t() | :scope_mismatch}
  def list_rule_presentations(%Scope{org_id: org_id} = scope, projects)
      when is_binary(org_id) and is_list(projects) do
    with {:ok, channels} <- list_channel_presentations(scope),
         channel_by_id <- Map.new(channels, &{&1.id, &1}) do
      projects
      |> Enum.reduce_while({:ok, []}, fn project, {:ok, rules} ->
        project_scope = Scope.put_project(scope, project.id)

        case list_rules_for_project(project.id, project_scope) do
          {:ok, project_rules} ->
            presentations =
              Enum.map(project_rules, fn rule ->
                Map.merge(rule_presentation(rule, project), %{
                  channel: Map.get(channel_by_id, rule.channel_id)
                })
              end)

            {:cont, {:ok, rules ++ presentations}}

          {:error, error} ->
            {:halt, {:error, error}}
        end
      end)
    end
  end

  def list_rule_presentations(_scope, _projects), do: {:error, :scope_mismatch}

  @doc "Creates a rule using a project-bound scope and returns its safe row."
  @spec create_rule(map(), Scope.t()) :: {:ok, map()} | {:error, term()}
  def create_rule(attrs, %Scope{org_id: org_id, project_id: project_id} = scope)
      when is_map(attrs) and is_binary(org_id) and is_binary(project_id) do
    with :ok <- ensure_scope_attribute(Map.get(attrs, :org_id), org_id),
         :ok <- ensure_scope_attribute(Map.get(attrs, :project_id), project_id),
         :ok <- project_in_scope(project_id, scope),
         :ok <- channel_in_scope(attrs, scope),
         {:ok, rule} <- Ash.create(AlertRule, attrs, action: :create, actor: scope) do
      {:ok, rule_presentation(rule, %{id: rule.project_id, name: "", public_token: nil})}
    end
  end

  def create_rule(_attrs, _scope), do: {:error, :scope_mismatch}

  @doc """
  Updates a rule through its project policy and returns a safe row.

  Accepts a rule id or any map that carries one.
  """
  @spec update_rule(String.t() | map(), map(), Scope.t()) :: {:ok, map()} | {:error, term()}
  def update_rule(rule_or_id, attrs, %Scope{org_id: org_id, project_id: project_id} = scope)
      when is_map(attrs) and is_binary(org_id) and is_binary(project_id) do
    with {:ok, rule_id} <- entity_id(rule_or_id),
         {:ok, rule} <- fetch_rule_for_mutation(rule_id, scope),
         :ok <- project_in_scope(rule.project_id, scope),
         :ok <- channel_in_scope(attrs, scope),
         {:ok, updated} <- Ash.update(rule, attrs, action: :update, actor: scope) do
      {:ok, rule_presentation(updated, %{id: updated.project_id, name: "", public_token: nil})}
    end
  end

  def update_rule(_rule_or_id, _attrs, _scope), do: {:error, :scope_mismatch}

  @doc "Destroys a project-scoped rule after policy evaluation."
  @spec delete_rule(String.t() | map(), Scope.t()) :: :ok | {:error, term()}
  def delete_rule(rule_or_id, %Scope{org_id: org_id, project_id: project_id} = scope)
      when is_binary(org_id) and is_binary(project_id) do
    with {:ok, rule_id} <- entity_id(rule_or_id),
         {:ok, rule} <- fetch_rule_for_mutation(rule_id, scope),
         false <- delivery_exists?(scope, alert_rule_id: rule.id),
         {:ok, _deleted} <- Ash.destroy(rule, action: :destroy, actor: scope) do
      :ok
    else
      true -> {:error, :deliveries_exist}
      error -> error
    end
  end

  def delete_rule(_rule_or_id, _scope), do: {:error, :scope_mismatch}

  @doc "Returns the newest delivery rows for the current organization only."
  @spec list_delivery_presentations(Scope.t(), pos_integer()) ::
          {:ok, [map()]} | {:error, Ash.Error.t() | :scope_mismatch}
  def list_delivery_presentations(scope, limit \\ @max_delivery_history)

  def list_delivery_presentations(%Scope{org_id: org_id} = scope, limit)
      when is_binary(org_id) and is_integer(limit) and limit > 0 do
    limit = Kernel.min(limit, @max_delivery_history)

    with {:ok, channels} <- list_channel_presentations(scope),
         channel_by_id <- Map.new(channels, &{&1.id, &1}),
         query <-
           Delivery
           |> Ash.Query.for_read(:read, %{}, actor: scope)
           |> Ash.Query.filter(org_id == ^org_id)
           |> Ash.Query.sort(inserted_at: :desc, id: :desc)
           |> Ash.Query.limit(limit),
         {:ok, deliveries} <- Ash.read(query) do
      {:ok,
       Enum.map(deliveries, fn delivery ->
         delivery_presentation(delivery, Map.get(channel_by_id, delivery.channel_id))
       end)}
    end
  end

  def list_delivery_presentations(_scope, _limit), do: {:error, :scope_mismatch}

  @doc "The channel types supported by the durable notification schema."
  def channel_types, do: @channel_types

  defp list_rules_for_project(project_id, %Scope{} = scope) do
    query =
      AlertRule
      |> Ash.Query.for_read(:list_for_project, %{project_id: project_id}, actor: scope)
      |> Ash.Query.sort(inserted_at: :desc)

    Ash.read(query)
  end

  defp with_default_selection(org_id, channel_id, true, fun) when is_function(fun, 0) do
    case Repo.transaction(fn ->
           clear_default_channel(org_id, channel_id)

           case fun.() do
             {:ok, value, notifications} -> {value, notifications}
             {:ok, value} -> {value, []}
             {:error, error} -> Repo.rollback(error)
           end
         end) do
      {:ok, {value, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, value}

      {:error, error} ->
        {:error, error}
    end
  end

  defp with_default_selection(_org_id, _channel_id, _is_default, fun)
       when is_function(fun, 0) do
    case fun.() do
      {:ok, value, notifications} ->
        Ash.Notifier.notify(notifications)
        {:ok, value}

      result ->
        result
    end
  end

  # Default selection must clear the previous row in the same database
  # transaction as the new write. The partial unique index then remains true
  # even when two requests switch defaults at the same time.
  defp clear_default_channel(org_id, nil) do
    Repo.query!(
      "UPDATE notification_channels SET is_default = false, updated_at = (now() AT TIME ZONE 'utc') WHERE org_id = $1 AND is_default = true",
      [org_id]
    )
  end

  defp clear_default_channel(org_id, channel_id) do
    Repo.query!(
      "UPDATE notification_channels SET is_default = false, updated_at = (now() AT TIME ZONE 'utc') WHERE org_id = $1 AND is_default = true AND id <> $2",
      [org_id, channel_id]
    )
  end

  defp delivery_exists?(%Scope{} = scope, filters) when is_list(filters) do
    query =
      Delivery
      |> Ash.Query.for_read(:read, %{}, actor: scope)
      |> Ash.Query.filter(org_id == ^scope.org_id)
      |> Ash.Query.limit(1)

    query =
      Enum.reduce(filters, query, fn
        {:channel_id, id}, query -> Ash.Query.filter(query, channel_id == ^id)
        {:alert_rule_id, id}, query -> Ash.Query.filter(query, alert_rule_id == ^id)
      end)

    case Ash.read(query) do
      {:ok, []} -> false
      {:ok, _deliveries} -> true
      {:error, _error} -> true
    end
  end

  defp fetch_channel_for_mutation(channel_id, scope) do
    query =
      Channel
      |> Ash.Query.for_read(:read, %{}, actor: scope)
      |> Ash.Query.filter(id == ^channel_id and org_id == ^scope.org_id)

    case Ash.read_one(query) do
      {:ok, nil} -> {:error, :not_found}
      result -> result
    end
  end

  defp fetch_rule_for_mutation(rule_id, scope) do
    query =
      AlertRule
      |> Ash.Query.for_read(:read, %{}, actor: scope)
      |> Ash.Query.filter(
        id == ^rule_id and org_id == ^scope.org_id and project_id == ^scope.project_id
      )

    case Ash.read_one(query) do
      {:ok, nil} -> {:error, :not_found}
      result -> result
    end
  end

  # AlertRule policies verify the caller's live manager role, but the rule
  # resource has scalar foreign keys rather than a cross-table org/project
  # constraint. Re-read the project with the requested organization pinned so
  # a forged Scope.put_project/2 cannot pair an organization with another
  # tenant's project.
  defp project_in_scope(project_id, %Scope{org_id: org_id} = scope)
       when is_binary(project_id) and is_binary(org_id) do
    query =
      Project
      |> Ash.Query.for_read(:read, %{}, actor: scope)
      |> Ash.Query.filter(id == ^project_id and org_id == ^org_id)

    case Ash.read_one(query) do
      {:ok, %Project{}} -> :ok
      {:ok, nil} -> {:error, :project_not_found}
      {:error, _error} -> {:error, :project_not_found}
    end
  end

  defp project_in_scope(_project_id, _scope), do: {:error, :project_not_found}

  defp channel_in_scope(%{channel_id: channel_id}, scope) when is_binary(channel_id) do
    case fetch_channel_for_mutation(channel_id, scope) do
      {:ok, _channel} -> :ok
      {:error, _error} -> {:error, :channel_not_found}
    end
  end

  defp channel_in_scope(_attrs, _scope), do: :ok

  defp ensure_scope_attribute(value, value), do: :ok
  defp ensure_scope_attribute(_value, _expected), do: {:error, :scope_mismatch}

  defp entity_id(id) when is_binary(id), do: {:ok, id}
  defp entity_id(%{id: id}) when is_binary(id), do: {:ok, id}
  defp entity_id(_other), do: {:error, :not_found}

  defp channel_presentation_for_id(channel_id, scope) do
    query =
      Channel
      |> Ash.Query.for_read(:read, %{}, actor: scope)
      |> Ash.Query.filter(id == ^channel_id and org_id == ^scope.org_id)
      |> Ash.Query.load(:config)

    case Ash.read_one(query) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, channel} -> {:ok, channel_presentation(channel)}
      {:error, error} -> {:error, error}
    end
  end

  defp channel_presentation(channel) do
    config = Map.get(channel, :config) || %{}

    %{
      id: channel.id,
      type: channel.type,
      name: channel.name,
      is_default: channel.is_default,
      inserted_at: channel.inserted_at,
      configured?: map_size(config) > 0,
      destination: safe_destination(channel.type, config)
    }
  end

  defp safe_destination("email", config) do
    case Map.get(config, "to") || Map.get(config, "email") do
      address when is_binary(address) -> mask_email(address)
      _ -> "Email destination configured"
    end
  end

  defp safe_destination(type, config) when type in ["slack", "discord"] do
    if Map.get(config, "webhook_url") || Map.get(config, "webhookUrl"),
      do: "Webhook destination configured",
      else: "Destination not configured"
  end

  defp safe_destination("webhook", config) do
    if Map.get(config, "url"), do: "HTTPS endpoint configured", else: "Endpoint not configured"
  end

  defp safe_destination("telegram", config) do
    if Map.get(config, "bot_token") || Map.get(config, "botToken"),
      do: "Telegram chat configured",
      else: "Chat not configured"
  end

  defp safe_destination(_type, _config), do: "Destination configured"

  defp mask_email(address) do
    case String.split(address, "@", parts: 2) do
      [local, domain] when byte_size(local) > 1 ->
        String.first(local) <> "•••@" <> domain

      [_local, domain] ->
        "•••@" <> domain

      _ ->
        "Email destination configured"
    end
  end

  defp rule_presentation(rule, project) do
    %{
      id: rule.id,
      org_id: rule.org_id,
      project_id: rule.project_id,
      project_name: Map.get(project, :name) || rule.project_id,
      module: rule.module,
      trigger_type: rule.trigger_type,
      condition: rule.condition || %{},
      channel_id: rule.channel_id,
      enabled: rule.enabled,
      inserted_at: rule.inserted_at,
      updated_at: rule.updated_at
    }
  end

  defp delivery_presentation(delivery, channel) do
    %{
      id: delivery.id,
      trigger: delivery.trigger,
      subject: subject_label(delivery.subject_type, delivery.subject_id),
      subject_type: delivery.subject_type,
      subject_id: delivery.subject_id,
      channel_id: delivery.channel_id,
      channel_type: delivery.channel_type,
      channel_name: channel && channel.name,
      status: delivery.status,
      attempt: delivery.attempt,
      sent_at: delivery.sent_at,
      inserted_at: delivery.inserted_at,
      error: safe_delivery_error(delivery.error_message)
    }
  end

  defp subject_label(nil, nil), do: "General alert"
  defp subject_label(type, nil), do: type
  defp subject_label(type, id), do: "#{type} #{id}"

  defp safe_delivery_error(nil), do: nil
  defp safe_delivery_error("retryable"), do: "Delivery will retry."
  defp safe_delivery_error("permanent"), do: "The destination rejected this delivery."
  defp safe_delivery_error(_error), do: "Delivery failed."
end
