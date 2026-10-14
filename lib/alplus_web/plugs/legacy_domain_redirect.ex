defmodule AlplusWeb.Plugs.LegacyDomainRedirect do
  @moduledoc "Redirects old public hosts to their PostDeploy equivalents."

  import Plug.Conn

  @hosts %{
    "alplus.dev" => {"postdeploy.dev", 301},
    "www.alplus.dev" => {"postdeploy.dev", 301},
    "aws.alplus.dev" => {"postdeploy.dev", 301},
    "console.alplus.dev" => {"postdeploy.dev", 301},
    "dash.alplus.dev" => {"postdeploy.dev", 301},
    "api.alplus.dev" => {"postdeploy.dev", 301},
    "www.postdeploy.dev" => {"postdeploy.dev", 301},
    "ingest.alplus.dev" => {"ingest.postdeploy.dev", 308},
    "ingestion.alplus.dev" => {"ingest.postdeploy.dev", 308}
  }

  @ingest_host "ingest.postdeploy.dev"

  def init(opts), do: opts

  def call(%Plug.Conn{host: host} = conn, _opts) do
    case redirect_target(conn, String.downcase(host)) do
      {:ok, {target_host, status}} ->
        location = "https://#{target_host}#{conn.request_path}#{query_suffix(conn.query_string)}"

        conn
        |> put_resp_header("location", location)
        |> send_resp(status, "")
        |> halt()

      :error ->
        conn
    end
  end

  defp redirect_target(conn, host) do
    case Map.fetch(@hosts, host) do
      {:ok, target} ->
        {:ok, target}

      :error ->
        if host == @ingest_host and browser_document?(conn),
          do: {:ok, {"postdeploy.dev", 301}},
          else: :error
    end
  end

  defp browser_document?(conn) do
    conn.method in ["GET", "HEAD"] and
      Enum.any?(get_req_header(conn, "accept"), &String.contains?(&1, "text/html"))
  end

  defp query_suffix(""), do: ""
  defp query_suffix(query), do: "?" <> query
end
