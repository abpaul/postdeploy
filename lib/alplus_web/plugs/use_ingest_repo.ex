defmodule AlplusWeb.Plugs.UseIngestRepo do
  @moduledoc "Routes all database calls in an ingest request through its reserved pool."

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    Alplus.Repo.put_dynamic_repo(Application.fetch_env!(:alplus, :ingest_repo))
    conn
  end
end
