defmodule AlplusWeb.Plugs.IngestAdmission do
  @moduledoc "Bounded global and per-Source admission for telemetry writes."

  @behaviour Plug

  import Plug.Conn

  alias Alplus.Ingest.Admission

  @impl true
  def init({scope, lane}) when scope in [:global, :tenant], do: {scope, lane}

  @impl true
  def call(conn, {:global, lane}) do
    case Admission.acquire(lane, :global) do
      :ok -> conn
      {:error, :overloaded} -> reject(conn, 503, "ingest_overloaded")
    end
  end

  def call(%{assigns: %{source: source}} = conn, {:tenant, lane}) do
    case Admission.acquire(lane, {:tenant, source.id}) do
      :ok -> conn
      {:error, :overloaded} -> reject(conn, 429, "tenant_concurrency_exceeded")
    end
  end

  def call(conn, {:tenant, _lane}), do: conn

  defp reject(conn, status, code) do
    Admission.release_all()

    conn
    |> put_resp_header("retry-after", "1")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: %{type: "overload_error", code: code}}))
    |> halt()
  end
end
