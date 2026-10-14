defmodule AlplusWeb.ArtifactUploadController do
  @moduledoc """
  `POST /e/artifacts?release=<version>&name=<file.js.map>` — uploads one
  source map for a release, authenticated by the same Observe Source
  bearer key as `/e/errors`. The raw request body is the map itself (no
  base64, no multipart), so a deploy step is one curl:

      curl -X POST "https://ingest.postdeploy.dev/e/artifacts?release=$VERSION&name=app.js.map" \\
        -H "Authorization: Bearer $POSTDEPLOY_API_KEY" \\
        -H "Content-Type: application/octet-stream" \\
        --data-binary @dist/app.js.map

  Send `Content-Type: application/octet-stream` (curl's default form
  encoding would route a multi-megabyte map through the urlencoded
  parser).

  The ingest preamble (bearer auth, tarpit, raw-body capture, size cap)
  runs as plugs on the `:artifact_ingest` pipeline with a 20 MiB body
  budget; this controller keeps only validation and storage.

  The release row is found or created for (Source, version), matching how
  ingest stamps `release` on events. Re-uploading the same name replaces
  the artifact (deploys retry; the newest map wins).
  """

  use AlplusWeb, :controller

  alias Alplus.Observe.Artifacts

  def create(conn, params) do
    source = conn.assigns.source
    release = Map.get(params, "release")
    name = Map.get(params, "name")

    case Artifacts.ingest(source, release, name, conn.assigns.raw_body) do
      {:ok, artifact} ->
        Alplus.Ingest.OperationalMonitor.outcome(:artifacts, source.id, 1, 0, :accepted)

        conn
        |> put_status(:created)
        |> json(%{id: artifact.id, name: artifact.name, sha256: artifact.sha256})

      {:error, :invalid_params} ->
        error(conn, :bad_request, "parameter_invalid")

      {:error, :invalid_source_map} ->
        error(conn, :bad_request, "validation_failed")

      {:error, {:store_failed, _reason}} ->
        unavailable(conn, source.id)
    end
  end

  defp error(conn, status, code) do
    conn
    |> put_status(status)
    |> json(%{error: %{type: "invalid_request_error", code: code}})
  end

  defp unavailable(conn, source_id) do
    Alplus.Ingest.OperationalMonitor.outcome(:artifacts, source_id, 0, 1, :unavailable)

    conn
    |> put_resp_header("retry-after", "1")
    |> error(:service_unavailable, "artifact_store_unavailable")
  end
end
