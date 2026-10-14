defmodule AlplusWeb.Plugs.IngestRawBodyTest do
  # No database and no HTTP server: a transport-level read failure cannot be
  # produced through a request, so drive the plug and stub the adapter.
  use ExUnit.Case, async: true

  alias AlplusWeb.Plugs.IngestRawBody

  defmodule FailingBodyAdapter do
    @moduledoc false

    def read_req_body(_state, _opts), do: {:error, :timeout}

    defdelegate send_resp(state, status, headers, body), to: Plug.Adapters.Test.Conn
  end

  test "a failed body read halts instead of reporting an empty body" do
    # `/m` would otherwise authenticate and write the query parameters of a
    # request whose body never arrived.
    conn =
      :post
      |> Plug.Test.conn("/m", "{}")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Map.update!(:adapter, fn {_module, state} -> {FailingBodyAdapter, state} end)
      |> IngestRawBody.call(1_048_576)

    assert conn.halted
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "parameter_invalid"
    refute Map.has_key?(conn.assigns, :raw_body)
  end
end
