defmodule Alplus.LoadTest.Adapter.InProcess do
  @moduledoc false
  @behaviour Alplus.LoadTest.Adapter

  @impl true
  def request(_base_url, token) do
    conn = Plug.Test.conn(:get, "/h/" <> token)
    response = AlplusWeb.Endpoint.call(conn, [])
    {:ok, response.status}
  rescue
    exception -> {:error, exception}
  end
end
