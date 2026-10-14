defmodule AlplusWeb.HealthController do
  @moduledoc "Load-balancer health endpoint that verifies database connectivity."

  use AlplusWeb, :controller

  alias Alplus.Repo

  def show(conn, _params) do
    conn = put_resp_content_type(conn, "text/plain")

    case Repo.query("SELECT 1", [], timeout: 1_000) do
      {:ok, _result} -> send_resp(conn, :ok, "ok")
      {:error, _reason} -> send_resp(conn, :service_unavailable, "unavailable")
    end
  end
end
