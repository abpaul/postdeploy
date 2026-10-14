defmodule Alplus.Mcp.Idempotency.RollbackError do
  @moduledoc """
  Carries an `Alplus.Mcp.Error` out of an `Ash.transaction/3` block.

  `Repo.rollback/1` hands its value to `Ash.Error.to_ash_error/1`, which
  normalizes a bespoke struct into `Ash.Error.Unknown` and loses `:code` and
  `:details`. Raising instead rolls the transaction back the same way and
  reaches the caller intact.
  """
  defexception [:error]

  @impl true
  def message(%__MODULE__{error: %Alplus.Mcp.Error{message: message}}), do: message
end

defmodule Alplus.Mcp.Idempotency do
  @moduledoc "Stores mutation results for seven days and rejects key reuse with new arguments."
  require Ash.Query

  alias Alplus.Mcp.{Error, IdempotencyRecord, Principal}
  alias Alplus.Mcp.Idempotency.RollbackError
  alias Alplus.Repo

  @result_key "__alplus_mcp_result__"
  @encrypted_prefix "v2:"
  @retention_seconds 7 * 24 * 60 * 60

  @spec run(
          Principal.t(),
          String.t(),
          map(),
          (-> {:ok, map()} | {:error, term()}),
          (map() -> :ok | {:error, term()})
        ) :: {:ok, map()} | {:error, Error.t()}
  def run(%Principal{} = principal, tool, args, fun, validator \\ &default_validator/1)
      when is_binary(tool) and is_map(args) and is_function(fun, 0) and
             is_function(validator, 1) do
    key = Map.get(args, "idempotency_key") || Map.get(args, :idempotency_key)

    if is_nil(key) or key == "" do
      {:error, Error.from(:missing_idempotency_key)}
    else
      request_hash = hash(args)

      outcome =
        try do
          Ash.transaction(
            IdempotencyRecord,
            fn ->
              lock_key(
                principal.org_id,
                principal.project_id,
                tool,
                key,
                principal.grant_id
              )

              case find(
                     principal.org_id,
                     principal.project_id,
                     tool,
                     key,
                     principal.grant_id
                   ) do
                {:ok, record} ->
                  if record.request_hash == request_hash do
                    case decode_result(record.result) do
                      {:ok, result} ->
                        {:cached, result}

                      :error ->
                        rollback!(
                          Error.new(
                            :invalid_argument,
                            "The cached mutation result is unreadable",
                            %{}
                          )
                        )
                    end
                  else
                    {:failed,
                     Error.new(
                       :idempotency_key_conflict,
                       "The idempotency key has different arguments",
                       %{resolution: "Use a new idempotency key for different arguments"}
                     )}
                  end

                :not_found ->
                  persist(principal, tool, key, request_hash, fun, validator)
              end
            end,
            return_notifications?: true
          )
        rescue
          rollback in RollbackError -> {:error, rollback.error}
        end

      case outcome do
        {:ok, {:cached, result}, notifications} ->
          Ash.Notifier.notify(notifications)
          {:ok, result}

        {:ok, {:persisted, result, record_notifications}, notifications} ->
          Ash.Notifier.notify(record_notifications ++ notifications)
          {:ok, result}

        {:ok, {:failed, %Error{} = error}, notifications} ->
          Ash.Notifier.notify(notifications)
          {:error, error}

        {:error, %Error{} = error} ->
          {:error, error}

        {:error, reason} ->
          {:error, Error.from(reason)}
      end
    end
  end

  @doc """
  Removes cached mutation results for an entry.

  Call this from the entry deletion transaction so the cache cannot outlive
  the content it describes.
  """
  @spec purge_entry(String.t(), String.t()) :: :ok
  def purge_entry(org_id, entry_id) when is_binary(org_id) and is_binary(entry_id) do
    case Repo.transaction(fn ->
           rows =
             Repo.query!(
               "SELECT id, result FROM mcp_idempotency_records WHERE org_id = $1 FOR UPDATE",
               [org_id]
             ).rows

           rows
           |> Enum.filter(&result_contains_entry?(&1, entry_id))
           |> Enum.each(fn [record_id, _result] ->
             Repo.query!("DELETE FROM mcp_idempotency_records WHERE id = $1", [record_id])
           end)

           :ok
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> raise "MCP idempotency purge failed: #{inspect(reason)}"
    end
  end

  defp result_contains_entry?([_record_id, result], entry_id) when is_map(result) do
    with {:ok, result} <- decode_result(result),
         %{entry: %{handle: ^entry_id}} <- result do
      true
    else
      _ -> false
    end
  end

  defp result_contains_entry?(_row, _entry_id), do: false

  # This binary is read from the idempotency table and was written by encode_result/1.
  # sobelow_skip ["Misc.BinToTerm"]
  defp safe_term(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> {:error, :invalid_term}
  end

  defp lock_key(org_id, project_id, tool, key, grant_id) do
    lock =
      Enum.map_join([org_id, project_id, tool, key, grant_id], "|", &to_string/1)

    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [lock])
    :ok
  end

  defp find(org_id, project_id, tool, key, grant_id) do
    IdempotencyRecord
    |> Ash.Query.filter(org_id == ^org_id and tool == ^tool and idempotency_key == ^key)
    |> project_filter(project_id)
    |> grant_filter(grant_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} ->
        :not_found

      {:ok, %{inserted_at: inserted_at} = record} ->
        if DateTime.compare(inserted_at, retention_cutoff()) == :lt do
          expire(record)
        else
          {:ok, record}
        end

      _ ->
        :not_found
    end
  end

  defp project_filter(query, nil), do: Ash.Query.filter(query, is_nil(project_id))

  defp project_filter(query, project_id) when is_binary(project_id),
    do: Ash.Query.filter(query, project_id == ^project_id)

  defp grant_filter(query, nil), do: Ash.Query.filter(query, is_nil(grant_id))

  defp grant_filter(query, grant_id) when is_binary(grant_id),
    do: Ash.Query.filter(query, grant_id == ^grant_id)

  defp retention_cutoff do
    DateTime.add(DateTime.utc_now(), -@retention_seconds, :second)
  end

  defp expire(record) do
    # The lookup and deletion share the caller's transaction and advisory lock.
    # Delete the expired row before persist/5 so the unique key can be reused.
    Repo.query!("DELETE FROM mcp_idempotency_records WHERE id = $1", [record.id])
    :not_found
  end

  defp persist(principal, tool, key, request_hash, fun, validator) do
    case fun.() do
      {:ok, result} when is_map(result) ->
        case validator.(result) do
          :ok ->
            store(principal, tool, key, request_hash, result)

          {:error, field} ->
            rollback!(
              Error.new(:invalid_result, "The action returned an invalid result", %{field: field})
            )
        end

      {:error, reason} ->
        {:failed, Error.from(reason)}

      other ->
        {:failed, Error.from(other)}
    end
  end

  defp store(principal, tool, key, request_hash, result) do
    with {:ok, encoded_result} <- encode_result(result) do
      attrs = %{
        org_id: principal.org_id,
        project_id: principal.project_id,
        grant_id: principal.grant_id,
        tool: tool,
        idempotency_key: key,
        request_hash: request_hash,
        result: encoded_result,
        inserted_at: DateTime.utc_now()
      }

      case Ash.create(IdempotencyRecord, attrs, authorize?: false, return_notifications?: true) do
        {:ok, _record, notifications} ->
          {:persisted, result, notifications}

        {:error, _error} ->
          rollback!(Error.new(:invalid_argument, "The mutation result could not be stored", %{}))
      end
    else
      {:error, _reason} ->
        rollback!(Error.new(:invalid_argument, "The mutation result could not be encrypted", %{}))
    end
  end

  # Rolls the transaction back the way `Repo.rollback/1` does, but keeps the
  # error whole. `run/5` rescues it immediately outside `Ash.transaction/3`.
  defp rollback!(%Error{} = error), do: raise(RollbackError, error: error)

  defp default_validator(_result), do: :ok

  defp encode_result(result) do
    result
    |> :erlang.term_to_binary()
    |> Alplus.NotificationsVault.encrypt()
    |> case do
      {:ok, ciphertext} ->
        {:ok, %{@result_key => @encrypted_prefix <> Base.encode64(ciphertext)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # This binary is read from the idempotency table and was written by
  # encode_result/1. The legacy branch keeps pre-encryption rows readable
  # until their normal seven-day retention expiry.
  defp decode_result(%{@result_key => @encrypted_prefix <> encoded}) when is_binary(encoded) do
    with {:ok, ciphertext} <- Base.decode64(encoded),
         {:ok, plaintext} <- Alplus.NotificationsVault.decrypt(ciphertext),
         {:ok, result} <- safe_term(plaintext) do
      {:ok, result}
    else
      _ -> :error
    end
  end

  defp decode_result(%{@result_key => encoded}) when is_binary(encoded) do
    with {:ok, binary} <- Base.decode64(encoded),
         {:ok, result} <- safe_term(binary) do
      {:ok, result}
    else
      _ -> :error
    end
  end

  defp decode_result(_result), do: :error

  defp hash(args) do
    args
    |> Map.delete("idempotency_key")
    |> Map.delete(:idempotency_key)
    |> Map.delete("_meta")
    |> Map.delete(:_meta)
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
