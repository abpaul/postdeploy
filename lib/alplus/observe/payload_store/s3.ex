defmodule Alplus.Observe.PayloadStore.S3 do
  @moduledoc false

  @behaviour Alplus.Observe.PayloadStore

  @impl true
  def put(key, payload) when is_binary(key) and is_binary(payload) do
    bucket = Application.fetch_env!(:alplus, :observe_payload_bucket)

    encryption =
      Application.get_env(:alplus, :observe_payload_s3_server_side_encryption, "AES256")

    encryption_opts =
      if encryption do
        [encryption: encryption]
      else
        []
      end

    bucket
    |> ExAws.S3.put_object(key, payload, [{:content_type, "application/json"} | encryption_opts])
    |> ExAws.request()
    |> case do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, {:s3_put_failed, reason}}
    end
  end

  @impl true
  def delete(key) when is_binary(key) do
    bucket = Application.fetch_env!(:alplus, :observe_payload_bucket)

    bucket
    |> ExAws.S3.delete_object(key)
    |> ExAws.request(http_opts: [recv_timeout: 5_000])
    |> case do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, {:s3_delete_failed, reason}}
    end
  end

  @impl true
  def get(key) when is_binary(key) do
    bucket = Application.fetch_env!(:alplus, :observe_payload_bucket)

    bucket
    |> ExAws.S3.get_object(key)
    |> ExAws.request()
    |> case do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, {:http_error, 404, _}} -> {:error, :not_found}
      {:error, {:error, :timeout}} -> {:error, :timeout}
      {:error, {:error, :closed}} -> {:error, :timeout}
      {:error, reason} -> {:error, {:s3_get_failed, reason}}
    end
  end
end
