defmodule AlplusWeb.AnalyticsExportController do
  use AlplusWeb, :controller

  @moduledoc """
  Downloads one project's raw analytics events for a window (ADR 0007).

  It exists so a customer is never locked in and can debug their own
  instrumentation against the exact rows PostDeploy holds. It is not an ETL
  interface: one window, one project, two formats, streamed in bounded
  pages.

  The signed-in session is the credential. An analytics write key cannot
  reach this route, because the write key authenticates only the ingest
  pipeline.
  """

  alias Alplus.Analytics.Queries

  @formats %{"ndjson" => "application/x-ndjson", "csv" => "text/csv"}
  @csv_columns ~w(id event_name distinct_id occurred_at properties)

  # The content type comes from the fixed `@formats` map, selected by
  # `format/1`, which falls back to "ndjson" for anything else. No request
  # value reaches the header.
  # sobelow_skip ["XSS.ContentType"]
  def show(conn, %{"org_token" => org_token, "project_token" => project_token} = params) do
    scope = project_scope(conn, org_token, project_token)
    format = format(params["format"])
    window = Queries.valid_window(params["window"])
    range = Queries.range(window)
    opts = source_opts(scope, params["source"])

    conn =
      conn
      |> put_resp_content_type(Map.fetch!(@formats, format))
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="analytics-#{window}.#{format}")
      )
      |> send_chunked(:ok)

    scope
    |> Queries.stream_events(range, 1_000, opts)
    |> encode(format)
    |> Enum.reduce_while(conn, fn line, conn ->
      case chunk(conn, line) do
        {:ok, conn} -> {:cont, conn}
        {:error, :closed} -> {:halt, conn}
      end
    end)
  end

  # An app reference that is not one of this project's own write keys exports
  # every app, exactly as the console does. The stream is project-scoped
  # either way, so this decides what the reader gets, never what they may
  # reach.
  defp source_opts(_scope, nil), do: []

  defp source_opts(scope, source_id) do
    known =
      scope.project_id
      |> Alplus.Sources.list_sources_for_project!(actor: scope)
      |> Enum.filter(&(&1.type == :analytics))
      |> Enum.map(& &1.id)

    if source_id in known, do: [source_id: source_id], else: []
  end

  defp encode(stream, "ndjson") do
    Stream.map(stream, fn event -> Jason.encode!(payload(event)) <> "\n" end)
  end

  defp encode(stream, "csv") do
    header = Stream.concat([Enum.join(@csv_columns, ",") <> "\n"], [])

    rows =
      Stream.map(stream, fn event ->
        event
        |> payload()
        |> then(fn map -> Enum.map(@csv_columns, &csv_cell(Map.fetch!(map, &1))) end)
        |> Enum.join(",")
        |> Kernel.<>("\n")
      end)

    Stream.concat(header, rows)
  end

  defp payload(event) do
    %{
      "id" => event.id,
      "event_name" => event.event_name,
      "distinct_id" => event.distinct_id,
      "occurred_at" => DateTime.to_iso8601(event.occurred_at),
      "properties" => event.properties
    }
  end

  # Quote every cell and double any embedded quote. An event name or a
  # property value is customer input, so it may hold a comma, a newline, or
  # a quote, and an unquoted cell would shift every later column.
  defp csv_cell(value) when is_binary(value),
    do: ~s(") <> String.replace(value, ~s("), ~s("")) <> ~s(")

  defp csv_cell(value) when is_map(value), do: csv_cell(Jason.encode!(value))
  defp csv_cell(value), do: csv_cell(to_string(value))

  defp format(format) when is_map_key(@formats, format), do: format
  defp format(_format), do: "ndjson"

  # Resolves the same org and project the console resolves, through the same
  # membership check. A cross-tenant reference raises the 404 every other
  # project route raises, never a 403.
  defp project_scope(conn, org_token, project_token) do
    user = conn.assigns.current_user || raise AlplusWeb.NotFoundError

    scope = Alplus.Scope.for_user(user.id)

    with {:ok, org} <- organization(scope, org_token),
         {:ok, org_scope} <- Alplus.Orgs.build_scope(scope, org.id),
         {:ok, project} <- project(org_scope, project_token) do
      Alplus.Scope.put_project(org_scope, project.id)
    else
      _ -> raise AlplusWeb.NotFoundError
    end
  end

  defp organization(scope, token) do
    Alplus.Orgs.list_organizations!(actor: scope)
    |> Enum.find(&(&1.public_token == token or &1.id == token))
    |> case do
      nil -> :error
      org -> {:ok, org}
    end
  end

  defp project(scope, token) do
    Alplus.Projects.list_projects_for_org!(scope.org_id, actor: scope)
    |> Enum.find(&(&1.public_token == token or &1.id == token))
    |> case do
      nil -> :error
      project -> {:ok, project}
    end
  end
end
