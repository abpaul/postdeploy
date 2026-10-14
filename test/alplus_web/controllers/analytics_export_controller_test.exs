defmodule AlplusWeb.AnalyticsExportControllerTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.AuditFixtures
  import Alplus.OrgsFixtures

  alias Alplus.Repo

  setup %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    subscribed_fixture(org)
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _secret} = source_fixture(scope, org, project, %{type: :analytics})

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(owner)

    %{conn: conn, org: org, scope: scope, project: project, source: source}
  end

  defp event(source, name, distinct_id, properties \\ %{}) do
    Repo.query!(
      """
      INSERT INTO product_events
        (id, org_id, project_id, source_id, environment, event_name, distinct_id,
         occurred_at, received_at, properties)
      VALUES ($1,$2,$3,$4,$5,$6,$7,now(),now(),$8)
      """,
      [
        Alplus.Id.generate(:product_event),
        source.org_id,
        source.project_id,
        source.id,
        source.environment,
        name,
        distinct_id,
        properties
      ]
    )
  end

  defp export_path(org, project, params) do
    "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/analytics/export?" <>
      URI.encode_query(params)
  end

  test "streams one JSON object per event", context do
    event(context.source, "meal_logged", "anon_1", %{"source" => "camera"})

    conn = get(context.conn, export_path(context.org, context.project, %{"format" => "ndjson"}))

    assert ["application/x-ndjson; charset=utf-8"] = get_resp_header(conn, "content-type")
    [line] = conn.resp_body |> String.split("\n", trim: true)

    assert %{"event_name" => "meal_logged", "distinct_id" => "anon_1", "properties" => props} =
             Jason.decode!(line)

    assert props == %{"source" => "camera"}
  end

  test "quotes a CSV cell that contains a comma", context do
    event(context.source, "report_exported", "anon_1", %{"note" => "one, two"})

    conn = get(context.conn, export_path(context.org, context.project, %{"format" => "csv"}))

    assert conn.resp_body =~ "id,event_name,distinct_id,occurred_at,properties"
    # The JSON properties column is one CSV cell, so its own quotes are
    # doubled and the embedded comma never shifts a column.
    assert conn.resp_body =~ ~s("{""note"":""one, two""}")
  end

  test "exports only the requesting project's events", context do
    other_project = project_fixture(context.scope, context.org, %{name: "Other"})
    agent_audit_fixture(context.scope, other_project)
    event(context.source, "meal_logged", "anon_1")

    conn = get(context.conn, export_path(context.org, other_project, %{"format" => "ndjson"}))

    assert conn.resp_body == ""
  end

  test "another organization's project is a 404", context do
    other_owner = user_fixture()
    {other_org, other_scope} = org_fixture(Alplus.Scope.for_user(other_owner.id))
    other_project = project_fixture(other_scope, other_org)

    assert_raise AlplusWeb.NotFoundError, fn ->
      get(context.conn, export_path(other_org, other_project, %{"format" => "ndjson"}))
    end
  end
end
