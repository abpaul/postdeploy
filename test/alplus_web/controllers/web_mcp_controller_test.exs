defmodule AlplusWeb.WebMcpControllerTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.OrgsFixtures

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  setup do
    user = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(user.id))
    project = project_fixture(scope, org)
    %{user: user, org: org, project: project}
  end

  test "an authenticated session receives the exact gateway catalog", %{
    conn: conn,
    user: user,
    org: org,
    project: project
  } do
    response =
      conn
      |> log_in(user)
      |> get("/dashboard/webmcp/catalog", %{org_id: org.id, project_handle: project.id})

    listed = json_response(response, 200)["tools"]

    expected =
      Alplus.Mcp.Gateway.wire_tools(%Alplus.Mcp.Principal{access: :read_write})
      |> Jason.encode!()
      |> Jason.decode!()

    assert listed == expected

    assert Enum.map(listed, & &1["name"]) == [
             "context.get",
             "actions.search",
             "actions.get",
             "actions.read",
             "actions.write",
             "actions.publish",
             "actions.destroy",
             "confirmations.get"
           ]
  end

  test "same-origin calls use CSRF and mark results untrusted", %{
    conn: conn,
    user: user,
    org: org,
    project: project
  } do
    conn = log_in(conn, user)
    csrf = Plug.CSRFProtection.get_csrf_token()

    response =
      conn
      |> put_req_header("x-csrf-token", csrf)
      |> post("/dashboard/webmcp/call", %{
        org_id: org.id,
        project_handle: project.id,
        tool: "actions.read",
        arguments: %{"action" => "projects.list", "arguments" => %{}}
      })

    assert response.status == 200
    assert json_response(response, 200)["ok"]
    assert json_response(response, 200)["untrusted"]
  end

  test "same-origin calls reject direct internal actions", %{
    conn: conn,
    user: user,
    org: org,
    project: project
  } do
    conn = log_in(conn, user)
    csrf = Plug.CSRFProtection.get_csrf_token()

    response =
      conn
      |> put_req_header("x-csrf-token", csrf)
      |> post("/dashboard/webmcp/call", %{
        org_id: org.id,
        project_handle: project.id,
        tool: "projects.list",
        arguments: %{}
      })

    assert json_response(response, 200)["ok"] == false
    assert json_response(response, 200)["error"]["code"] == "not_found"
  end

  test "pre-cancelled same-origin calls return the stable cancellation envelope", %{
    conn: conn,
    user: user,
    org: org,
    project: project
  } do
    conn = log_in(conn, user)
    csrf = Plug.CSRFProtection.get_csrf_token()

    response =
      conn
      |> put_req_header("x-csrf-token", csrf)
      |> put_req_header("x-webmcp-cancel", "true")
      |> post("/dashboard/webmcp/call", %{
        org_id: org.id,
        project_handle: project.id,
        tool: "actions.read",
        arguments: %{"action" => "projects.list", "arguments" => %{}}
      })

    assert json_response(response, 200) == %{
             "ok" => false,
             "error" => %{
               "code" => "cancelled",
               "message" => "The operation was cancelled"
             }
           }
  end

  test "cross-tenant catalog requests reveal no membership detail", %{conn: conn, user: user} do
    other_user = user_fixture()
    {other_org, other_scope} = org_fixture(Alplus.Scope.for_user(other_user.id))
    other_project = project_fixture(other_scope, other_org)

    response =
      conn
      |> log_in(user)
      |> get("/dashboard/webmcp/catalog", %{
        org_id: other_org.id,
        project_handle: other_project.id
      })

    assert response.status == 404
    refute response.resp_body =~ other_org.id
    refute response.resp_body =~ "forbidden"
  end
end
