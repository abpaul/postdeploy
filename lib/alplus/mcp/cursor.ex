defmodule Alplus.Mcp.Cursor do
  @moduledoc "Signs opaque, tenant-bound cursors with a 24-hour lifetime."

  alias Alplus.Mcp.Principal

  @ttl_seconds 86_400

  @spec encode(Principal.t(), String.t(), map(), term()) :: String.t()
  def encode(%Principal{} = principal, tool, filters, value)
      when is_binary(tool) and is_map(filters) do
    encode_at(principal, tool, filters, value, System.system_time(:second))
  end

  @doc false
  @spec encode_at(Principal.t(), String.t(), map(), term(), integer()) :: String.t()
  def encode_at(%Principal{} = principal, tool, filters, value, issued_at)
      when is_binary(tool) and is_map(filters) and is_integer(issued_at) do
    payload = %{
      org_id: principal.org_id,
      project_id: principal.project_id,
      user_id: principal.user_id,
      grant_id: principal.grant_id,
      tool: tool,
      filters: filters,
      sort: Map.get(filters, :sort, Map.get(filters, "sort", "newest")),
      value: value,
      issued_at: issued_at
    }

    encoded = payload |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)
    signature = sign(encoded)
    encoded <> "." <> signature
  end

  @spec decode(Principal.t(), String.t(), map(), String.t()) ::
          {:ok, term()} | {:error, :invalid_cursor | :cursor_expired}
  def decode(%Principal{} = principal, tool, filters, token)
      when is_binary(tool) and is_map(filters) and is_binary(token) do
    with [encoded, signature] <- String.split(token, ".", parts: 2),
         true <- Plug.Crypto.secure_compare(sign(encoded), signature),
         {:ok, payload} <- decode_payload(encoded),
         :ok <- validate(payload, principal, tool, filters) do
      {:ok, payload.value}
    else
      {:error, :cursor_expired} -> {:error, :cursor_expired}
      _ -> {:error, :invalid_cursor}
    end
  end

  def decode(_principal, _tool, _filters, _token), do: {:error, :invalid_cursor}

  # The caller verifies the HMAC before this signed cursor payload is decoded.
  # sobelow_skip ["Misc.BinToTerm"]
  defp decode_payload(encoded) do
    encoded
    |> Base.url_decode64(padding: false)
    |> case do
      {:ok, binary} ->
        try do
          {:ok, :erlang.binary_to_term(binary, [:safe])}
        rescue
          ArgumentError -> {:error, :invalid_cursor}
        end

      :error ->
        {:error, :invalid_cursor}
    end
  end

  defp validate(
         %{
           org_id: org_id,
           project_id: project_id,
           user_id: user_id,
           grant_id: grant_id,
           tool: tool,
           filters: cursor_filters,
           sort: sort,
           issued_at: issued_at
         },
         principal,
         tool,
         filters
       ) do
    expected_sort = Map.get(filters, :sort, Map.get(filters, "sort", "newest"))

    cond do
      org_id != principal.org_id or project_id != principal.project_id or
        user_id != principal.user_id or grant_id != principal.grant_id or
        cursor_filters != filters or sort != expected_sort ->
        {:error, :invalid_cursor}

      not is_integer(issued_at) or System.system_time(:second) - issued_at > @ttl_seconds ->
        {:error, :cursor_expired}

      issued_at > System.system_time(:second) + 60 ->
        {:error, :invalid_cursor}

      true ->
        :ok
    end
  end

  defp validate(_payload, _principal, _tool, _filters), do: {:error, :invalid_cursor}

  defp sign(encoded) do
    secret = Application.fetch_env!(:alplus, :token_signing_secret)
    key = Plug.Crypto.KeyGenerator.generate(secret, "mcp cursor v1")

    :crypto.mac(:hmac, :sha256, key, encoded) |> Base.url_encode64(padding: false)
  end
end
