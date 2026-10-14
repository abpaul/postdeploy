defmodule AlplusWeb.Plugs.IngestFault do
  @moduledoc "Development-only database latency injection for overload recovery tests."

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    delay_ms = Application.get_env(:alplus, :ingest_db_delay_ms, 0)

    if delay_ms > 0 do
      _result =
        Alplus.Repo.query("SELECT pg_sleep($1)", [delay_ms / 1_000], timeout: delay_ms + 1_000)
    end

    conn
  end
end
