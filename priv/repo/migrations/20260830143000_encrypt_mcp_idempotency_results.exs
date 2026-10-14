defmodule Alplus.Repo.Migrations.EncryptMcpIdempotencyResults do
  use Ecto.Migration

  @result_key "__alplus_mcp_result__"
  @encrypted_prefix "v2:"

  def up do
    started_vault? = ensure_vault_started!()

    try do
      encrypt_all()
    after
      stop_vault(started_vault?)
    end
  end

  def down do
    started_vault? = ensure_vault_started!()

    try do
      decrypt_all()
    after
      stop_vault(started_vault?)
    end
  end

  defp encrypt_all do
    repo().query!("SELECT id, result FROM mcp_idempotency_records").rows
    |> Enum.each(fn [id, result] ->
      case encrypt_legacy_result(result) do
        {:ok, encrypted} ->
          repo().query!(
            "UPDATE mcp_idempotency_records SET result = $1 WHERE id = $2",
            [encrypted, id]
          )

        :already_encrypted ->
          :ok

        {:error, reason} ->
          raise "cannot encrypt MCP idempotency result #{id}: #{inspect(reason)}"
      end
    end)
  end

  defp decrypt_all do
    repo().query!("SELECT id, result FROM mcp_idempotency_records").rows
    |> Enum.each(fn [id, result] ->
      case decrypt_result(result) do
        {:ok, legacy} ->
          repo().query!(
            "UPDATE mcp_idempotency_records SET result = $1 WHERE id = $2",
            [legacy, id]
          )

        :already_legacy ->
          :ok

        {:error, reason} ->
          raise "cannot decrypt MCP idempotency result #{id}: #{inspect(reason)}"
      end
    end)
  end

  defp encrypt_legacy_result(%{@result_key => @encrypted_prefix <> _}), do: :already_encrypted

  defp encrypt_legacy_result(%{@result_key => encoded}) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, binary} -> encrypt_binary(binary)
      :error -> {:error, :invalid_base64}
    end
  end

  defp encrypt_legacy_result(result) when is_map(result) do
    result
    |> :erlang.term_to_binary()
    |> encrypt_binary()
  end

  defp encrypt_legacy_result(_result), do: {:error, :invalid_legacy_result}

  defp decrypt_result(%{@result_key => @encrypted_prefix <> encoded}) when is_binary(encoded) do
    with {:ok, ciphertext} <- Base.decode64(encoded),
         {:ok, binary} <- Alplus.NotificationsVault.decrypt(ciphertext),
         {:ok, result} <- safe_term(binary),
         true <- is_map(result) do
      {:ok, result}
    else
      _ -> {:error, :invalid_encrypted_result}
    end
  end

  defp decrypt_result(result) when is_map(result), do: :already_legacy
  defp decrypt_result(_result), do: {:error, :invalid_encrypted_result}

  defp encrypt_binary(binary) do
    case Alplus.NotificationsVault.encrypt(binary) do
      {:ok, ciphertext} ->
        {:ok, %{@result_key => @encrypted_prefix <> Base.encode64(ciphertext)}}

      {:error, _reason} ->
        {:error, :encryption_failed}
    end
  end

  # `mix test` runs this migration through `ash.setup` in the same BEAM that
  # then boots the application. A vault left running here makes
  # `Alplus.Application` fail with "already started", so stop what we start.
  defp ensure_vault_started! do
    case Process.whereis(Alplus.NotificationsVault) do
      nil ->
        case Alplus.NotificationsVault.start_link() do
          {:ok, _pid} -> true
          {:error, {:already_started, _pid}} -> false
          {:error, reason} -> raise "cannot start notifications vault: #{inspect(reason)}"
        end

      _pid ->
        false
    end
  end

  defp stop_vault(true), do: GenServer.stop(Alplus.NotificationsVault)
  defp stop_vault(false), do: :ok

  defp safe_term(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> {:error, :invalid_term}
  end
end
