defmodule Alplus.Mcp.Confirmations do
  @moduledoc "Durable destructive-action confirmation workflow."

  require Ash.Query

  alias Alplus.Mcp.{Confirmation, Dispatch, Error, Principal}
  alias Alplus.{Repo, Scope}

  @expiry_seconds 10 * 60

  @type result :: {:ok, Confirmation.t()} | {:error, term()}

  @doc "Creates (or returns) the durable approval record for a destructive action."
  @spec request(Principal.t(), String.t(), map(), String.t()) :: result()
  def request(
        %Principal{org_id: org_id, project_id: project_id, user_id: user_id} = principal,
        action,
        arguments,
        idempotency_key
      )
      when is_binary(org_id) and is_binary(project_id) and is_binary(user_id) and
             is_binary(action) and is_map(arguments) and is_binary(idempotency_key) do
    now = DateTime.utc_now()

    attrs = %{
      org_id: org_id,
      project_id: project_id,
      grant_id: principal.grant_id,
      user_id: user_id,
      principal_source: Atom.to_string(principal.source),
      scopes: principal.scopes || [],
      action: action,
      arguments: arguments,
      idempotency_key: idempotency_key,
      requested_at: now,
      expires_at: DateTime.add(now, @expiry_seconds, :second),
      correlation_id: principal.correlation_id
    }

    case Alplus.Mcp.request_confirmation(attrs, actor: principal) do
      {:ok, confirmation} ->
        {:ok, confirmation}

      {:error, _reason} = error ->
        resolve_existing(principal, action, arguments, idempotency_key, error)
    end
  end

  def request(_principal, _action, _arguments, _idempotency_key),
    do:
      {:error,
       Error.new(
         :invalid_argument,
         "A project, action, arguments, and idempotency key are required",
         %{}
       )}

  @doc "Returns a confirmation visible to this principal, expiring stale pending rows."
  @spec get(Principal.t(), String.t()) :: result()
  def get(%Principal{} = principal, id) when is_binary(id) do
    with {:ok, confirmation} <- fetch_for_principal(principal, id),
         {:ok, confirmation} <- expire_if_needed(confirmation, principal),
         {:ok, confirmation} <- Ash.load(confirmation, [:result], actor: principal) do
      {:ok, confirmation}
    else
      _ -> {:error, :not_found}
    end
  end

  def get(_principal, _id), do: {:error, :not_found}

  @doc "Lists pending confirmations for the selected dashboard project."
  @spec pending(Scope.t()) :: {:ok, [Confirmation.t()]} | {:error, term()}
  def pending(%Scope{} = scope) do
    with {:ok, fresh_scope} <- reauthorize(scope),
         {:ok, confirmations} <-
           Alplus.Mcp.list_confirmations_for_project(fresh_scope.project_id, actor: fresh_scope) do
      confirmations = Enum.map(confirmations, &expire_if_needed_for_scope(&1, fresh_scope))
      {:ok, Enum.filter(confirmations, &(&1.status == "pending"))}
    end
  end

  def pending(_scope), do: {:error, :forbidden}

  @doc "Approves and executes a pending action once, under a row lock."
  @spec approve(Scope.t(), String.t()) :: result()
  def approve(%Scope{} = scope, id) when is_binary(id) do
    with {:ok, fresh_scope} <- reauthorize(scope) do
      case Repo.transaction(fn -> approve_locked(fresh_scope, id) end) do
        {:ok, {:done, result, notifications}} ->
          Ash.Notifier.notify(notifications)
          {:ok, result}

        {:ok, {:execute, approved, notifications}} ->
          Ash.Notifier.notify(notifications)
          execute_approved(approved, fresh_scope)

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error, :forbidden}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def approve(_scope, _id), do: {:error, :not_found}

  @doc "Rejects a pending action without executing it."
  @spec reject(Scope.t(), String.t()) :: result()
  def reject(%Scope{} = scope, id) when is_binary(id) do
    with {:ok, fresh_scope} <- reauthorize(scope) do
      case Repo.transaction(fn -> reject_locked(fresh_scope, id) end) do
        {:ok, {result, notifications}} ->
          Ash.Notifier.notify(notifications)
          {:ok, result}

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error, :forbidden}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def reject(_scope, _id), do: {:error, :not_found}

  defp resolve_existing(principal, action, arguments, idempotency_key, original_error) do
    case fetch_identity(principal, action, idempotency_key) do
      {:ok, existing} ->
        case load_arguments(existing, principal) do
          {:ok, ^arguments} -> {:ok, existing}
          _ -> {:error, :idempotency_conflict}
        end

      _ ->
        original_error
    end
  end

  defp fetch_identity(%Principal{} = principal, action, key) do
    query =
      Confirmation
      |> Ash.Query.for_read(:read, %{}, actor: principal)
      |> Ash.Query.filter(
        org_id == ^principal.org_id and project_id == ^principal.project_id and
          user_id == ^principal.user_id and action == ^action and idempotency_key == ^key
      )

    if is_nil(principal.grant_id),
      do: Ash.Query.filter(query, is_nil(grant_id)),
      else: Ash.Query.filter(query, grant_id == ^principal.grant_id)

    case Ash.read_one(query, actor: principal) do
      {:ok, %Confirmation{} = confirmation} -> {:ok, confirmation}
      _ -> {:error, :not_found}
    end
  end

  defp fetch_for_principal(%Principal{} = principal, id) do
    case fetch_identity_by_id(principal, id) do
      {:ok, confirmation} -> {:ok, confirmation}
      _ -> {:error, :not_found}
    end
  end

  defp fetch_identity_by_id(%Principal{} = principal, id) do
    query =
      Confirmation
      |> Ash.Query.for_read(:read, %{}, actor: principal)
      |> Ash.Query.filter(
        id == ^id and org_id == ^principal.org_id and project_id == ^principal.project_id and
          user_id == ^principal.user_id
      )

    if is_nil(principal.grant_id),
      do: Ash.Query.filter(query, is_nil(grant_id)),
      else: Ash.Query.filter(query, grant_id == ^principal.grant_id)

    case Ash.read_one(query, actor: principal) do
      {:ok, %Confirmation{} = confirmation} -> {:ok, confirmation}
      _ -> {:error, :not_found}
    end
  end

  defp load_arguments(%Confirmation{} = confirmation, actor) do
    case Ash.load(confirmation, [:arguments], actor: actor) do
      {:ok, %{arguments: arguments}} -> {:ok, arguments}
      error -> error
    end
  end

  defp expire_if_needed(
         %Confirmation{status: "pending", expires_at: expires_at} = confirmation,
         actor
       )
       when is_struct(expires_at, DateTime) do
    if DateTime.compare(expires_at, DateTime.utc_now()) != :gt do
      attrs = %{status: "expired", execution_finished_at: DateTime.utc_now()}

      case transition(confirmation, attrs, actor, authorize?: false) do
        {:ok, updated, notifications} ->
          Ash.Notifier.notify(notifications)
          {:ok, updated}

        error ->
          error
      end
    else
      {:ok, confirmation}
    end
  end

  defp expire_if_needed(confirmation, _actor), do: {:ok, confirmation}

  defp expire_if_needed_for_scope(confirmation, scope) do
    case expire_if_needed(confirmation, scope) do
      {:ok, updated} -> updated
      _ -> confirmation
    end
  end

  defp approve_locked(scope, id) do
    case lock_and_fetch(scope, id) do
      {:ok, %{status: status} = confirmation} when status != "pending" ->
        {:done, confirmation, []}

      {:ok, confirmation} ->
        case maybe_expire_locked(confirmation, scope) do
          {:expired, expired, notifications} ->
            {:done, expired, notifications}

          {:ok, current} ->
            case mark_approved(current, scope) do
              {:ok, approved, notifications} -> {:execute, approved, notifications}
              {:error, reason} -> Repo.rollback(reason)
            end
        end

      {:error, :not_found} ->
        Repo.rollback(:not_found)
    end
  end

  defp maybe_expire_locked(confirmation, scope) do
    if DateTime.compare(confirmation.expires_at, DateTime.utc_now()) != :gt do
      case transition(
             confirmation,
             %{status: "expired", execution_finished_at: DateTime.utc_now()},
             scope,
             authorize?: false
           ) do
        {:ok, expired, notifications} -> {:expired, expired, notifications}
        {:error, reason} -> Repo.rollback(reason)
      end
    else
      {:ok, confirmation}
    end
  end

  defp mark_approved(confirmation, scope) do
    now = DateTime.utc_now()

    transition(
      confirmation,
      %{status: "approved", approved_at: now, execution_started_at: now},
      scope
    )
  end

  defp execute_approved(%Confirmation{} = confirmation, scope) do
    with {:ok, arguments} <- load_arguments(confirmation, scope),
         arguments <- Map.put_new(arguments, "idempotency_key", confirmation.idempotency_key),
         principal <- principal_for_confirmation(confirmation, scope),
         {:ok, result} <- Dispatch.call(confirmation.action, arguments, principal) do
      transition_after_commit(
        confirmation,
        %{status: "approved", result: result, execution_finished_at: DateTime.utc_now()},
        scope
      )
    else
      {:error, %Error{} = error} ->
        mark_failed(confirmation, scope, error.message)

      {:error, _reason} ->
        mark_failed(confirmation, scope, "The action could not be completed.")
    end
  end

  defp mark_failed(confirmation, scope, message) do
    transition_after_commit(
      confirmation,
      %{status: "failed", error: message, execution_finished_at: DateTime.utc_now()},
      scope
    )
  end

  defp transition_after_commit(confirmation, attrs, actor) do
    case transition(confirmation, attrs, actor) do
      {:ok, updated, notifications} ->
        Ash.Notifier.notify(notifications)
        {:ok, updated}

      error ->
        error
    end
  end

  defp reject_locked(scope, id) do
    with {:ok, confirmation} <- lock_and_fetch(scope, id),
         {:ok, rejected, notifications} <- reject_pending(confirmation, scope) do
      {rejected, notifications}
    else
      {:error, :not_found} -> Repo.rollback(:not_found)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp reject_pending(%Confirmation{status: "pending"} = confirmation, scope) do
    if DateTime.compare(confirmation.expires_at, DateTime.utc_now()) != :gt do
      transition(
        confirmation,
        %{status: "expired", execution_finished_at: DateTime.utc_now()},
        scope,
        authorize?: false
      )
    else
      transition(
        confirmation,
        %{status: "rejected", rejected_at: DateTime.utc_now()},
        scope
      )
    end
  end

  defp reject_pending(confirmation, _scope), do: {:ok, confirmation, []}

  defp lock_and_fetch(scope, id) do
    case Repo.query("SELECT id FROM mcp_confirmations WHERE id = $1 FOR UPDATE", [id]) do
      {:ok, %{rows: [[^id]]}} ->
        case Ash.get(Confirmation, id, actor: scope) do
          {:ok, %Confirmation{} = confirmation} -> {:ok, confirmation}
          _ -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp transition(confirmation, attrs, actor, opts \\ []) do
    Ash.update(confirmation, attrs,
      action: :transition,
      actor: actor,
      authorize?: Keyword.get(opts, :authorize?, true),
      return_notifications?: true
    )
  end

  defp reauthorize(%Scope{user_id: user_id, org_id: org_id, project_id: project_id})
       when is_binary(user_id) and is_binary(org_id) and is_binary(project_id) do
    with {:ok, base} <- Alplus.Orgs.build_scope(Scope.for_user(user_id), org_id),
         {:ok, _project} <- Alplus.Projects.get_project(project_id, actor: base),
         true <- base.role in ["owner", "admin"] do
      {:ok, Scope.put_project(base, project_id)}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp reauthorize(_scope), do: {:error, :forbidden}

  defp principal_for_confirmation(%Confirmation{} = confirmation, %Scope{} = scope) do
    %Principal{
      grant_id: confirmation.grant_id,
      org_id: scope.org_id,
      project_id: scope.project_id,
      user_id: confirmation.user_id,
      role: scope.role,
      correlation_id: confirmation.correlation_id,
      scopes: confirmation.scopes,
      access: :read_write,
      source: principal_source(confirmation.principal_source)
    }
  end

  defp principal_source("oauth"), do: :oauth
  defp principal_source(_source), do: :session
end
