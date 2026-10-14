defmodule Alplus.LoadTest.Adapter.HTTP do
  @moduledoc false
  @behaviour Alplus.LoadTest.Adapter

  @impl true
  def request(base_url, token) do
    case Req.get(base_url <> "/h/" <> token, retry: false, receive_timeout: 10_000) do
      {:ok, %{status: status}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end
end
