defmodule AlplusWeb.McpScopeEndpointTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Mcp
  alias Alplus.Mcp.OAuth

  setup do
    user = user_fixture()
    {org, owner_scope} = org_fixture(scope_fixture(%{user: user}))
    project = project_fixture(owner_scope, org, %{name: "Scope HTTP Project"})
    actor = Alplus.Scope.put_project(owner_scope, project.id)

    %{user: user, org: org, project: project, actor: actor}
  end

  describe "tools/list" do
    test "lists exactly the gateway tools for every persisted OAuth scope", %{actor: actor} do
      for granted <- [["projects:read"], ["monitor:write"]] do
        token = issue_access_token(actor, granted)
        listed = list_tools(token)

        assert listed.status == 200
        assert tool_names(listed) == gateway_tool_names()
        refute Enum.any?(tool_names(listed), &String.contains?(&1, ".list"))
        refute_secrets(listed, [token])
      end
    end
  end

  describe "tools/call" do
    test "rejects direct internal action names at the wire boundary", %{actor: actor} do
      token = issue_access_token(actor, ["projects:read"])
      session_id = initialize_session(token)
      response = call_tool(token, session_id, "projects.list", %{})

      assert response.status == 200
      assert structured_error_code(response) == "not_found"
      refute_secrets(response, [token])
    end

    test "executes a registered action through its gateway tool", %{actor: actor} do
      token = issue_access_token(actor, ["projects:read"])
      session_id = initialize_session(token)

      response =
        call_tool(token, session_id, "actions.read", %{
          "action" => "projects.list",
          "arguments" => %{}
        })

      assert_tool_succeeded(response, [token])

      assert is_list(
               get_in(decoded(response), [
                 "result",
                 "structuredContent",
                 "result",
                 "projects"
               ])
             )
    end
  end

  describe "pinned grant" do
    test "denies a token bound to a different resource", %{actor: actor} do
      token = issue_access_token(actor, ["projects:read"], OAuth.resource_uri() <> "/other")
      response = post_mcp(build_conn(), token, request("tools/list"))

      assert response.status == 401

      assert get_resp_header(response, "www-authenticate") == [
               ~s(Bearer error="invalid_token", resource_metadata="#{prm_url()}")
             ]

      refute_secrets(response, [token])
    end

    test "keeps a trailing slash compatible with legacy project grants", %{actor: actor} do
      token = issue_access_token(actor, ["projects:read"])
      session_id = initialize_session(token, "/mcp/")
      response = call_tool(token, session_id, "context.get", %{}, "/mcp/")

      assert response.status == 200
      refute_tool_error(response, "not_found")
    end

    test "uses the OAuth-pinned project instead of a caller-supplied project", %{
      actor: actor,
      org: org
    } do
      other_project = project_fixture(actor, org, %{name: "Other project"})
      {foreign_org, foreign_scope} = org_fixture(scope_fixture())
      foreign_project = project_fixture(foreign_scope, foreign_org)

      token = issue_access_token(actor, ["analytics:read"])
      session_id = initialize_session(token)

      for handle <- [other_project.id, foreign_project.id] do
        response =
          call_tool(token, session_id, "actions.read", %{
            "action" => "measure.list_sites",
            "arguments" => %{"project_handle" => handle}
          })

        assert response.status == 200
        refute_tool_error(response, "not_found")
        refute response.resp_body =~ handle
        refute_secrets(response, [token])
      end
    end
  end

  describe "organization grant" do
    test "discovers current and future projects and requires request-local project context", %{
      actor: actor,
      org: org,
      project: project
    } do
      token = issue_organization_access_token(actor, org, ["analytics:read", "projects:read"])
      endpoint = "/mcp/org/#{org.public_token}"
      future_project = project_fixture(actor, org, %{name: "Future project"})
      session_id = initialize_session(token, endpoint)

      context = call_tool(token, session_id, "context.get", %{}, endpoint)
      assert context.status == 200

      project_refs =
        context
        |> decoded()
        |> get_in(["result", "structuredContent", "projects"])
        |> Enum.map(& &1["project_ref"])

      assert MapSet.new(project_refs) ==
               MapSet.new([project.public_token, future_project.public_token])

      exact =
        call_tool(
          token,
          session_id,
          "context.get",
          %{"project_ref" => future_project.public_token},
          endpoint
        )

      assert get_in(decoded(exact), [
               "result",
               "structuredContent",
               "project",
               "project_ref"
             ]) == future_project.public_token

      logs = Alplus.Audit.list_audit_logs!(actor: actor)

      assert Enum.any?(logs, fn log ->
               log.action == "context.get" and log.project_id == future_project.id and
                 log.grant_id != nil
             end)

      missing =
        call_tool(
          token,
          session_id,
          "actions.read",
          %{"action" => "measure.list_sites", "arguments" => %{}},
          endpoint
        )

      assert structured_error_code(missing) == "project_required"

      allowed =
        call_tool(
          token,
          session_id,
          "actions.read",
          %{
            "project_ref" => future_project.public_token,
            "action" => "measure.list_sites",
            "arguments" => %{}
          },
          endpoint
        )

      write_denied =
        call_tool(
          token,
          session_id,
          "actions.write",
          %{
            "project_ref" => future_project.public_token,
            "action" => "measure.create_event_definition",
            "arguments" => %{"name" => "checkout"},
            "idempotency_key" => "read-grant-write-attempt"
          },
          endpoint
        )

      assert structured_error_code(write_denied) == "insufficient_scope"
      refute_tool_error(allowed, "not_found")

      :ok = Ash.destroy(future_project, action: :archive, actor: actor)

      archived =
        call_tool(
          token,
          session_id,
          "context.get",
          %{"project_ref" => future_project.public_token},
          endpoint
        )

      assert structured_error_code(archived) == "not_found"
    end

    test "rejects foreign projects and cross-resource token use", %{
      actor: actor,
      org: org
    } do
      {foreign_org, foreign_scope} = org_fixture(scope_fixture())
      foreign_project = project_fixture(foreign_scope, foreign_org)
      token = issue_organization_access_token(actor, org, ["analytics:read"])
      endpoint = "/mcp/org/#{org.public_token}"
      session_id = initialize_session(token, endpoint)

      denied =
        call_tool(
          token,
          session_id,
          "actions.read",
          %{
            "project_ref" => foreign_project.public_token,
            "action" => "measure.list_sites",
            "arguments" => %{}
          },
          endpoint
        )

      assert structured_error_code(denied) == "not_found"
      assert post_mcp(build_conn(), token, request("tools/list")).status == 401

      legacy_token = issue_access_token(actor, ["projects:read"])

      assert post_mcp(build_conn(), legacy_token, request("tools/list"), endpoint).status ==
               401
    end

    test "membership removal invalidates an organization token on the next request", %{
      actor: actor,
      org: org
    } do
      token = issue_organization_access_token(actor, org, ["projects:read"])
      endpoint = "/mcp/org/#{org.public_token}"

      Alplus.Repo.query!("DELETE FROM memberships WHERE org_id = $1 AND user_id = $2", [
        org.id,
        actor.user_id
      ])

      assert post_mcp(build_conn(), token, request("tools/list"), endpoint).status == 401
    end

    test "role downgrade invalidates write-scoped organization access", %{
      actor: actor,
      org: org
    } do
      token =
        issue_organization_access_token(actor, org, ["projects:read", "monitor:write"])

      endpoint = "/mcp/org/#{org.public_token}"

      Alplus.Repo.query!(
        "UPDATE memberships SET role = 'member' WHERE org_id = $1 AND user_id = $2",
        [org.id, actor.user_id]
      )

      assert post_mcp(build_conn(), token, request("tools/list"), endpoint).status == 401
    end

    test "validates project_ref against a legacy pinned grant", %{
      actor: actor,
      org: org
    } do
      other_project = project_fixture(actor, org, %{name: "Legacy mismatch"})
      token = issue_access_token(actor, ["analytics:read"])
      session_id = initialize_session(token)

      response =
        call_tool(token, session_id, "actions.read", %{
          "project_ref" => other_project.public_token,
          "action" => "measure.list_sites",
          "arguments" => %{}
        })

      assert structured_error_code(response) == "not_found"
    end
  end

  defp issue_access_token(actor, scopes, resource \\ OAuth.resource_uri()) do
    {:ok, client} = cache_client!()

    {:ok, grant} =
      Mcp.authorize_oauth_grant(
        %{
          org_id: actor.org_id,
          project_id: actor.project_id,
          user_id: actor.user_id,
          oauth_client_id: client.id,
          issuer: OAuth.issuer(),
          resource: resource,
          scopes: scopes
        },
        actor: actor
      )

    {:ok, access_token} =
      Mcp.issue_oauth_access_token(
        %{
          grant_id: grant.id,
          resource: resource,
          scopes: scopes
        },
        authorize?: false
      )

    token = Ash.Resource.get_metadata(access_token, :token)
    assert is_binary(token) and token != ""
    assert grant.scopes == scopes
    assert access_token.scopes == scopes
    token
  end

  defp issue_organization_access_token(actor, org, scopes) do
    {:ok, client} = cache_client!()
    resource = OAuth.resource_uri(org.public_token)

    {:ok, grant} =
      Mcp.authorize_oauth_grant(
        %{
          org_id: actor.org_id,
          project_id: nil,
          scope_mode: "organization",
          user_id: actor.user_id,
          oauth_client_id: client.id,
          issuer: OAuth.issuer(),
          resource: resource,
          scopes: scopes
        },
        actor: actor
      )

    {:ok, access_token} =
      Mcp.issue_oauth_access_token(
        %{grant_id: grant.id, resource: resource, scopes: scopes},
        authorize?: false
      )

    Ash.Resource.get_metadata(access_token, :token)
  end

  defp cache_client! do
    now = DateTime.utc_now()

    Mcp.cache_oauth_client(
      %{
        issuer: OAuth.issuer(),
        client_id:
          "https://client.example/mcp-scope-endpoint-#{System.unique_integer([:positive])}.json",
        client_name: "MCP scope endpoint test client",
        redirect_uris: ["https://client.example/oauth/callback"],
        fetched_at: now,
        expires_at: DateTime.add(now, 3600, :second)
      },
      authorize?: false
    )
  end

  defp list_tools(token) do
    session_id = initialize_session(token)

    build_conn()
    |> put_req_header("mcp-session-id", session_id)
    |> post_mcp(token, request("tools/list"))
  end

  defp initialize_session(token, path \\ "/mcp") do
    response =
      post_mcp(
        build_conn(),
        token,
        request("initialize", %{
          "clientInfo" => %{"name" => "scope-endpoint-test", "version" => "1.0.0"},
          "capabilities" => %{}
        }),
        path
      )

    assert response.status == 200
    refute_secrets(response, [token])
    [session_id] = get_resp_header(response, "mcp-session-id")
    session_id
  end

  defp call_tool(token, session_id, name, arguments, path \\ "/mcp") do
    body =
      request("tools/call", %{"name" => name, "arguments" => arguments})
      |> Map.put("id", "scope-call-#{System.unique_integer([:positive])}")

    build_conn()
    |> put_req_header("mcp-session-id", session_id)
    |> post_mcp(token, body, path)
  end

  defp assert_tool_succeeded(response, secrets) do
    body = decoded(response)

    assert response.status == 200
    assert body["result"]["isError"] == false
    refute_secrets(response, secrets)
  end

  defp tool_names(response) do
    response
    |> decoded()
    |> get_in(["result", "tools"])
    |> List.wrap()
    |> Enum.map(& &1["name"])
  end

  defp gateway_tool_names do
    ~w(context.get actions.search actions.get actions.read actions.write actions.publish actions.destroy confirmations.get)
  end

  defp refute_tool_error(response, code) do
    refute structured_error_code(response) == code
  end

  defp structured_error_code(response) do
    get_in(decoded(response), ["result", "structuredContent", "error", "code"])
  end

  defp decoded(response) do
    case Jason.decode(response.resp_body) do
      {:ok, body} when is_map(body) -> body
      _ -> %{}
    end
  end

  defp refute_secrets(response, secrets) do
    Enum.each(secrets, fn secret ->
      refute is_binary(secret) and secret != "" and String.contains?(response.resp_body, secret)
    end)
  end

  defp prm_url, do: OAuth.protected_resource_metadata_uri()

  defp request(method, params \\ %{}) do
    %{
      "id" => "scope-#{method}",
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => Map.put(params, "protocolVersion", "2025-11-25")
    }
  end

  defp post_mcp(conn, token, body, path \\ "/mcp") do
    conn
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-protocol-version", "2025-11-25")
    |> put_req_header("authorization", "Bearer #{token}")
    |> post(path, Jason.encode!(body))
  end
end
