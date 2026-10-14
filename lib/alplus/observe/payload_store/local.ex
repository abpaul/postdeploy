defmodule Alplus.Observe.PayloadStore.Local do
  @moduledoc """
  File-backed payload store for LOCAL DEVELOPMENT only (configured in
  `config/dev.exs`). Production stays on `PayloadStore.S3`; test on
  `PayloadStore.Fake`. Keys are sanitized into a fixed root so a crafted
  key can never escape it.
  """

  @behaviour Alplus.Observe.PayloadStore

  @root "tmp/observe_payload_store"

  @impl true
  # The fixed root and sanitized key segments prevent traversal.
  # sobelow_skip ["Traversal.FileModule"]
  def put(key, payload) do
    path = path_for(key)
    File.mkdir_p!(Path.dirname(path))
    File.write(path, payload)
  end

  @impl true
  # sobelow_skip ["Traversal.FileModule"]
  def delete(key) do
    case File.rm(path_for(key)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  # sobelow_skip ["Traversal.FileModule"]
  def get(key) do
    case File.read(path_for(key)) do
      {:ok, binary} -> {:ok, binary}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp path_for(key) do
    safe =
      key
      |> String.split("/")
      |> Enum.map(&String.replace(&1, ~r/[^A-Za-z0-9._-]/, "_"))
      |> Enum.reject(&(&1 in ["", ".", ".."]))
      |> Path.join()

    Path.join(@root, safe)
  end
end
