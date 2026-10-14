defmodule Alplus.Observe.PayloadStore do
  @moduledoc false
  @max_inline_bytes 256 * 1024
  @max_outbox_bytes 1_048_576

  @callback put(String.t(), binary()) :: :ok | {:error, term()}
  @callback get(String.t()) :: {:ok, binary()} | {:error, :not_found | :timeout | term()}
  @callback delete(String.t()) :: :ok | {:error, term()}

  @type fetch_error :: :not_found | :timeout | :fetch_failed | :unparseable

  # Returns the deterministic S3 key and bounded bytes to persist in the
  # outbox. Encoding is deliberately side-effect free: object storage runs
  # only after the event transaction commits.
  @spec prepare(map(), String.t()) ::
          {:ok, %{key: String.t(), payload: binary()} | nil} | {:error, term()}
  def prepare(item, project_id) when is_map(item) and is_binary(project_id) do
    with {:ok, encoded} <- Jason.encode(item) do
      cond do
        byte_size(encoded) > @max_outbox_bytes ->
          {:error, :payload_too_large}

        byte_size(encoded) > @max_inline_bytes ->
          {:ok, %{key: "events/#{project_id}/#{item["id"]}.json", payload: encoded}}

        true ->
          {:ok, nil}
      end
    end
  end

  # Full-payload, on-demand fetch for the issue-detail evidence view. Never
  # returns a silent empty: every failure carries one of the typed reasons
  # the LiveView renders distinct messaging for.
  @spec fetch(String.t()) :: {:ok, map()} | {:error, fetch_error()}
  def fetch(key) when is_binary(key) do
    case adapter().get(key) do
      {:ok, binary} ->
        case Jason.decode(binary) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          _ -> {:error, :unparseable}
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, _reason} ->
        {:error, :fetch_failed}
    end
  end

  # Raw-binary storage for non-event objects (release artifacts / source
  # maps). Same adapter and error surface as the event path; no JSON
  # decode on fetch because a source map is consumed as bytes.
  @spec store_raw(String.t(), binary()) :: :ok | {:error, term()}
  def store_raw(key, binary) when is_binary(key) and is_binary(binary),
    do: adapter().put(key, binary)

  @doc """
  Deletes one stored payload object through the configured adapter. Used by
  the inactive-organization purge worker (issue #61 item 14); a missing
  object already counts as deleted, so a retry never fails.
  """
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key) when is_binary(key) do
    case adapter().delete(key) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec fetch_raw(String.t()) :: {:ok, binary()} | {:error, fetch_error()}
  def fetch_raw(key) when is_binary(key) do
    case adapter().get(key) do
      {:ok, binary} -> {:ok, binary}
      {:error, :not_found} -> {:error, :not_found}
      {:error, :timeout} -> {:error, :timeout}
      {:error, _reason} -> {:error, :fetch_failed}
    end
  end

  defp adapter, do: Application.fetch_env!(:alplus, :observe_payload_store)
end
