defmodule Alplus.Mcp.BoundaryMutationAdapter do
  @behaviour Alplus.Mcp.Adapter

  alias Alplus.Mcp.{Principal, Tool}

  @impl true
  def prefix, do: "test"

  @impl true
  def tools do
    [
      %Tool{
        name: "test.mutate",
        title: "Test mutation",
        description: "Test mutation",
        input_schema: %{"type" => "object"},
        output_schema: %{"type" => "object"},
        annotations: %{},
        cost_weight: 1,
        requires_access: :read_write
      }
    ]
  end

  @impl true
  def call("test.mutate", args, %Principal{}), do: {:ok, %{"value" => args["value"]}}
end

defmodule Alplus.Mcp.BoundaryMissingProjectAdapter do
  @behaviour Alplus.Mcp.Adapter

  alias Alplus.Mcp.{Principal, Tool}

  @impl true
  def prefix, do: "unsafe"

  @impl true
  def tools do
    [
      %Tool{
        name: "unsafe.lookup",
        title: "Unsafe lookup",
        description: "A deliberately misdeclared project tool",
        input_schema: %{"type" => "object"},
        output_schema: %{"type" => "object"},
        annotations: %{},
        cost_weight: 1,
        requires_access: :read
      }
    ]
  end

  @impl true
  def call("unsafe.lookup", _args, %Principal{}), do: {:ok, %{"called" => true}}
end

defmodule Alplus.Mcp.BoundaryNotFoundAdapter do
  @behaviour Alplus.Mcp.Adapter

  alias Alplus.Mcp.{Error, Principal, Tool}

  @impl true
  def prefix, do: "probe"

  @impl true
  def tools do
    [
      %Tool{
        name: "probe.lookup",
        title: "Probe",
        description: "Probe",
        input_schema: %{"type" => "object"},
        output_schema: %{"type" => "object"},
        annotations: %{},
        cost_weight: 1,
        requires_access: :read
      }
    ]
  end

  @impl true
  def call("probe.lookup", _args, %Principal{}), do: {:error, Error.from(:not_found)}
end

defmodule Alplus.Mcp.BoundaryTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Mcp
  alias Alplus.Mcp.{Audit, Cursor, Error, Idempotency, OAuth, Principal, RateLimit, Tenancy}
  alias Alplus.Repo

  @read_scopes ["projects:read", "analytics:read", "changelog:read"]
  @write_scopes ["projects:read", "analytics:read", "changelog:write"]

  setup do
    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org, %{slug: "boundary-api"})
    actor = Alplus.Scope.put_project(scope, project.id)
    {grant, token} = issue_oauth(actor, @read_scopes)

    %{
      org: org,
      scope: scope,
      actor: actor,
      project: project,
      grant: grant,
      token: token
    }
  end

  test "rejects absent and malformed credentials with unauthenticated", %{token: token} do
    assert {:error, :unauthenticated} =
             Alplus.Mcp.Authorization.authenticate(Plug.Test.conn(:post, "/mcp"))

    conn =
      Plug.Test.conn(:post, "/mcp")
      |> Plug.Conn.put_req_header("authorization", "Basic #{token}")

    assert {:error, :unauthenticated} = Alplus.Mcp.Authorization.authenticate(conn)
  end

  test "legacy mcred tokens never authenticate" do
    for token <- [
          "mcred_unknown",
          "mcred_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
        ] do
      conn =
        Plug.Test.conn(:post, "/mcp")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")

      assert {:error, :unauthenticated} = Alplus.Mcp.Authorization.authenticate(conn)
    end
  end

  test "rejects a query-string token even when the header is valid", %{token: token} do
    conn = Plug.Test.conn(:post, "/mcp")
    conn = %{conn | query_string: "access_token=#{URI.encode_www_form(token)}"}
    conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")

    assert {:error, :unauthenticated} = Alplus.Mcp.Authorization.authenticate(conn)
  end

  test "authenticates an OAuth principal pinned to the grant project", %{
    token: token,
    project: project,
    grant: grant
  } do
    conn =
      Plug.Test.conn(:post, "/mcp")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")

    assert {:ok, principal} = Alplus.Mcp.Authorization.authenticate(conn)
    keys = principal_keys(principal)

    assert principal.grant_id == grant.id
    assert String.starts_with?(principal.grant_id, "mcogr_")
    assert principal.project_id == project.id
    assert principal.source == :oauth
    assert principal.scopes == @read_scopes
    refute :credential_id in keys
  end

  test "resolves a project only inside the granted organization", %{
    grant: grant,
    project: project
  } do
    principal = oauth_principal(grant)
    assert {:ok, scope} = Tenancy.resolve(principal, project.id)
    assert scope.project_id == project.id
    assert scope.grant_id == grant.id
    refute :credential_id in Map.keys(Map.from_struct(scope))

    assert {:error, :not_found} = Tenancy.resolve(principal, "proj_other_org")
  end

  test "projects.list pages newest projects without repeats", %{
    org: org,
    scope: scope,
    project: existing,
    grant: grant
  } do
    created =
      Enum.map(1..2, fn index ->
        project_fixture(scope, org, %{name: "Page #{index}"})
      end)

    principal = %{oauth_principal(grant) | project_id: nil}
    expected = MapSet.new([existing.id | Enum.map(created, & &1.id)])

    assert {:ok, %{projects: first, next_cursor: cursor}} =
             Alplus.Projects.McpAdapter.call("projects.list", %{"limit" => 2}, principal)

    assert is_binary(cursor)
    assert length(first) == 2

    assert {:ok, %{projects: second, next_cursor: nil}} =
             Alplus.Projects.McpAdapter.call(
               "projects.list",
               %{"limit" => 2, "cursor" => cursor},
               principal
             )

    handles = Enum.map(first ++ second, & &1.handle)
    assert length(handles) == 3
    assert length(Enum.uniq(handles)) == 3
    assert MapSet.new(handles) == expected
  end

  test "projects.list uses the id tiebreaker for equal insertion timestamps", %{
    org: org,
    scope: scope,
    project: existing,
    grant: grant
  } do
    other = project_fixture(scope, org, %{name: "Equal timestamp"})
    inserted_at = ~N[2026-01-01 00:00:00.000000]

    for project <- [existing, other] do
      Repo.query!("UPDATE projects SET inserted_at = $1 WHERE id = $2", [inserted_at, project.id])
    end

    principal = %{oauth_principal(grant) | project_id: nil}
    expected = [existing.id, other.id] |> Enum.sort(:desc)

    assert {:ok, %{projects: first, next_cursor: cursor}} =
             Alplus.Projects.McpAdapter.call("projects.list", %{"limit" => 1}, principal)

    assert {:ok, %{projects: second, next_cursor: nil}} =
             Alplus.Projects.McpAdapter.call(
               "projects.list",
               %{"limit" => 1, "cursor" => cursor},
               principal
             )

    assert Enum.map(first ++ second, & &1.handle) == expected
  end

  test "projects.list rejects invalid limits with the accepted range and received value", %{
    grant: grant
  } do
    principal = oauth_principal(grant)

    for limit <- ["abc", 0, 101] do
      assert {:error,
              %{
                code: :invalid_argument,
                details: %{field: "limit", value: ^limit, minimum: 1, maximum: 100}
              }} =
               Alplus.Projects.McpAdapter.call("projects.list", %{"limit" => limit}, principal)
    end
  end

  test "round trips cursors and rejects tampering and another organization", %{
    org: org,
    grant: grant
  } do
    principal = oauth_principal(grant)
    other = %Principal{principal | org_id: org.id <> "_other"}
    cursor = Cursor.encode(principal, "projects.list", %{}, 50)

    assert {:ok, 50} = Cursor.decode(principal, "projects.list", %{}, cursor)
    assert {:error, :invalid_cursor} = Cursor.decode(other, "projects.list", %{}, cursor)

    assert {:error, :invalid_cursor} =
             Cursor.decode(principal, "projects.list", %{}, cursor <> "tampered")
  end

  test "projects.list fails closed after membership removal", %{
    org: org,
    scope: scope,
    grant: grant
  } do
    principal = oauth_principal(grant)

    Alplus.Repo.query!("DELETE FROM memberships WHERE org_id = $1 AND user_id = $2", [
      org.id,
      scope.user_id
    ])

    assert {:error, %Error{code: :not_found}} =
             Alplus.Projects.McpAdapter.call("projects.list", %{}, principal)
  end

  test "boundary permits the explicit organization-scoped projects.list tool", %{
    project: project,
    grant: grant
  } do
    project_id = project.id

    assert {:ok, %{projects: projects}} =
             Alplus.Mcp.Dispatch.call("projects.list", %{}, oauth_principal(grant))

    assert [%{handle: ^project_id}] = projects
  end

  test "a project-pinned OAuth grant cannot resolve, list, read, or mutate a sibling project", %{
    org: org,
    scope: scope,
    actor: actor,
    project: project,
    grant: grant
  } do
    sibling = project_fixture(scope, org, %{name: "Sibling"})
    {other_org, other_scope} = org_fixture(scope_fixture())
    foreign = project_fixture(other_scope, other_org)
    principal = oauth_principal(grant)

    assert {:ok, %{projects: [%{handle: handle}]}} =
             Alplus.Projects.McpAdapter.call("projects.list", %{}, principal)

    assert handle == project.id
    refute handle == sibling.id

    assert {:error, :not_found} = Tenancy.resolve(principal, sibling.id)
    assert {:error, :not_found} = Tenancy.resolve(principal, foreign.id)

    assert {:error, %{code: :not_found}} =
             Alplus.Mcp.Dispatch.call(
               "measure.list_sites",
               %{"project_handle" => sibling.id},
               principal
             )

    assert {:error, %{code: :not_found}} =
             Alplus.Mcp.Dispatch.call(
               "measure.list_sites",
               %{"project_handle" => foreign.id},
               principal
             )

    {write_grant, _write_token} = issue_oauth(actor, @write_scopes)
    write_principal = oauth_principal(write_grant)

    assert {:error, %{code: :not_found}} =
             Alplus.Mcp.Dispatch.call(
               "changelog.upsert_draft",
               %{
                 "project_handle" => sibling.id,
                 "idempotency_key" => "sibling-write",
                 "external_id" => "sibling",
                 "markdown" => "---\ntitle: Sibling\n---\nbody"
               },
               write_principal
             )

    assert {:error, %{code: :not_found}} =
             Alplus.Mcp.Dispatch.call(
               "changelog.upsert_draft",
               %{
                 "project_handle" => foreign.id,
                 "idempotency_key" => "foreign-write",
                 "external_id" => "foreign",
                 "markdown" => "---\ntitle: Foreign\n---\nbody"
               },
               write_principal
             )
  end

  test "boundary rejects a tool that omits its required project handle", %{
    org: org,
    scope: scope,
    project: project
  } do
    previous = Application.get_env(:alplus, :mcp_adapters)
    Application.put_env(:alplus, :mcp_adapters, [Alplus.Mcp.BoundaryMissingProjectAdapter])
    on_exit(fn -> Application.put_env(:alplus, :mcp_adapters, previous) end)

    assert {:error, %{code: :invalid_argument, details: %{field: "project_handle"}}} =
             Alplus.Mcp.Dispatch.call(
               "unsafe.lookup",
               %{},
               session_principal(scope, org, project)
             )
  end

  test "authentication fails closed after membership removal", %{
    org: org,
    scope: scope,
    token: token
  } do
    Alplus.Repo.query!("DELETE FROM memberships WHERE org_id = $1 AND user_id = $2", [
      org.id,
      scope.user_id
    ])

    conn =
      Plug.Test.conn(:post, "/mcp")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")

    assert {:error, :unauthenticated} = Alplus.Mcp.Authorization.authenticate(conn)
  end

  test "rejects expired cursors", %{grant: grant} do
    principal = oauth_principal(grant)

    payload = %{
      org_id: principal.org_id,
      project_id: principal.project_id,
      user_id: principal.user_id,
      grant_id: principal.grant_id,
      tool: "projects.list",
      filters: %{},
      sort: "newest",
      value: 50,
      issued_at: System.system_time(:second) - 86_401
    }

    encoded = payload |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)

    secret = Application.fetch_env!(:alplus, :token_signing_secret)
    key = Plug.Crypto.KeyGenerator.generate(secret, "mcp cursor v1")
    signature = :crypto.mac(:hmac, :sha256, key, encoded) |> Base.url_encode64(padding: false)

    assert {:error, :cursor_expired} =
             Cursor.decode(principal, "projects.list", %{}, encoded <> "." <> signature)
  end

  test "dispatch stores and replays a mutation result", %{
    org: org,
    scope: scope,
    project: project
  } do
    previous = Application.get_env(:alplus, :mcp_adapters)
    Application.put_env(:alplus, :mcp_adapters, [Alplus.Mcp.BoundaryMutationAdapter])

    on_exit(fn -> Application.put_env(:alplus, :mcp_adapters, previous) end)

    write_principal = session_principal(scope, org, project)
    member_scope = member_fixture(scope, org, user_fixture(), "member")
    read_principal = session_principal(member_scope, org, project)

    args = %{
      "idempotency_key" => "dispatch-key",
      "value" => "first",
      "project_handle" => project.id
    }

    assert {:ok, %{"value" => "first"}} =
             Alplus.Mcp.Dispatch.call("test.mutate", args, write_principal)

    assert {:ok, %{"value" => "first"}} =
             Alplus.Mcp.Dispatch.call("test.mutate", args, write_principal)

    assert {:error, %{code: :forbidden_role}} =
             Alplus.Mcp.Dispatch.call("test.mutate", args, read_principal)
  end

  test "audits slug success, denial, and redacted source metadata", %{
    org: org,
    scope: scope,
    project: project
  } do
    previous = Application.get_env(:alplus, :mcp_adapters)
    Application.put_env(:alplus, :mcp_adapters, [Alplus.Mcp.BoundaryMutationAdapter])
    on_exit(fn -> Application.put_env(:alplus, :mcp_adapters, previous) end)

    write_principal = session_principal(scope, org, project)
    assert {:ok, _scope} = Tenancy.resolve(write_principal, project.id)

    assert {:ok, _result} =
             Alplus.Mcp.Dispatch.call(
               "test.mutate",
               %{
                 "idempotency_key" => "audit-slug",
                 "value" => "slug",
                 "project_handle" => project.id
               },
               write_principal
             )

    member_scope = member_fixture(scope, org, user_fixture(), "member")
    read_principal = session_principal(member_scope, org, project)

    assert {:error, %{code: :forbidden_role}} =
             Alplus.Mcp.Dispatch.call(
               "test.mutate",
               %{"value" => "denied", "project_handle" => project.id},
               read_principal
             )

    sources =
      Enum.map(1..5, fn index ->
        %{
          "kind" => "issue",
          "url" => "https://example.com/" <> String.duplicate("#{index}", 2_000)
        }
      end)

    assert {:ok, _result} =
             Alplus.Mcp.Dispatch.call(
               "test.mutate",
               %{
                 "idempotency_key" => "audit-large",
                 "value" => "large",
                 "project_handle" => project.id,
                 "sources" => sources
               },
               write_principal
             )

    assert %{rows: [[project_id, outcome, grant_id, actor_kind, transport]]} =
             Alplus.Repo.query!(
               "SELECT project_id, outcome, grant_id, actor_kind, transport FROM audit_logs WHERE request_id = $1 ORDER BY inserted_at DESC LIMIT 1",
               [write_principal.correlation_id]
             )

    assert project_id == project.id
    assert outcome == "allowed"
    assert grant_id == nil
    assert actor_kind == "agent"
    assert transport == "webmcp"

    assert %{rows: [[denied_outcome]]} =
             Alplus.Repo.query!(
               "SELECT outcome FROM audit_logs WHERE request_id = $1 AND outcome = 'denied'",
               [read_principal.correlation_id]
             )

    assert denied_outcome == "denied"

    assert %{rows: [[metadata]]} =
             Alplus.Repo.query!(
               "SELECT metadata FROM audit_logs WHERE request_id = $1 ORDER BY inserted_at DESC LIMIT 1",
               [write_principal.correlation_id]
             )

    assert metadata["sources"]["count"] == 5
    assert metadata["sources"]["kinds"] == List.duplicate("issue", 5)
    refute Jason.encode!(metadata) =~ "https://example.com/"
  end

  test "remote OAuth calls audit grant_id over remote_mcp", %{
    grant: grant,
    project: project
  } do
    principal = oauth_principal(grant)

    assert {:ok, _result} =
             Alplus.Mcp.Dispatch.call("projects.list", %{}, principal)

    assert %{rows: [[grant_id, actor_kind, transport]]} =
             Alplus.Repo.query!(
               "SELECT grant_id, actor_kind, transport FROM audit_logs WHERE request_id = $1",
               [principal.correlation_id]
             )

    assert grant_id == grant.id
    assert String.starts_with?(grant_id, "mcogr_")
    assert actor_kind == "agent"
    assert transport == "remote_mcp"
    assert project.id == principal.project_id
  end

  test "audits cross-tenant not_found as denied", %{
    org: org,
    scope: scope,
    project: project
  } do
    previous = Application.get_env(:alplus, :mcp_adapters)
    Application.put_env(:alplus, :mcp_adapters, [Alplus.Mcp.BoundaryNotFoundAdapter])
    on_exit(fn -> Application.put_env(:alplus, :mcp_adapters, previous) end)

    principal = session_principal(scope, org, project)

    assert {:error, %{code: :not_found}} =
             Alplus.Mcp.Dispatch.call(
               "probe.lookup",
               %{"project_handle" => "other-tenant-project"},
               principal
             )

    assert %{rows: [["denied"]]} =
             Alplus.Repo.query!(
               "SELECT outcome FROM audit_logs WHERE request_id = $1",
               [principal.correlation_id]
             )
  end

  test "serializes concurrent retries and executes one mutation", %{grant: grant} do
    principal = oauth_principal(grant)
    counter = start_supervised!({Agent, fn -> 0 end})
    args = %{"idempotency_key" => "concurrent", "value" => "once"}

    results =
      1..2
      |> Task.async_stream(
        fn _ ->
          Idempotency.run(principal, "test.mutate", args, fn ->
            Agent.update(counter, &(&1 + 1))
            {:ok, %{value: "stored"}}
          end)
        end,
        max_concurrency: 2,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert results == [{:ok, %{value: "stored"}}, {:ok, %{value: "stored"}}]
    assert Agent.get(counter, & &1) == 1
  end

  test "expires a stale idempotency row and reuses its key", %{grant: grant} do
    principal = oauth_principal(grant)
    args = %{"idempotency_key" => "stale", "value" => "old"}

    request_hash =
      args
      |> Map.delete("idempotency_key")
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    result = %{"__alplus_mcp_result__" => Base.encode64(:erlang.term_to_binary(%{value: "old"}))}

    Ash.create!(
      Alplus.Mcp.IdempotencyRecord,
      %{
        org_id: principal.org_id,
        tool: "test.mutate",
        idempotency_key: "stale",
        request_hash: request_hash,
        result: result,
        inserted_at: DateTime.add(DateTime.utc_now(), -8 * 24 * 60 * 60, :second)
      },
      authorize?: false
    )

    assert {:ok, %{value: "new"}} =
             Idempotency.run(principal, "test.mutate", args, fn ->
               {:ok, %{value: "new"}}
             end)
  end

  test "returns stored idempotency results and rejects changed arguments", %{
    grant: grant
  } do
    principal = oauth_principal(grant)
    args = %{"idempotency_key" => "key-1", "value" => "first"}

    assert {:ok, %{value: "stored"}} =
             Idempotency.run(principal, "test.mutate", args, fn -> {:ok, %{value: "stored"}} end)

    assert {:ok, %{value: "stored"}} =
             Idempotency.run(principal, "test.mutate", args, fn -> {:ok, %{value: "new"}} end)

    conflict =
      Idempotency.run(
        principal,
        "test.mutate",
        %{"idempotency_key" => "key-1", "value" => "different"},
        fn -> {:ok, %{value: "bad"}} end
      )

    assert {:error, %{code: :idempotency_key_conflict}} = conflict
  end

  test "idempotency ignores protocol metadata and encrypts returned credentials", %{grant: grant} do
    principal = oauth_principal(grant)
    args = %{"idempotency_key" => "meta-key", "value" => "same", "_meta" => %{"trace" => "one"}}
    secret = "one-time-secret-#{System.unique_integer([:positive])}"

    assert {:ok, %{"secret" => ^secret}} =
             Idempotency.run(principal, "test.mutate", args, fn ->
               {:ok, %{"secret" => secret}}
             end)

    assert {:ok, %{"secret" => ^secret}} =
             Idempotency.run(
               principal,
               "test.mutate",
               Map.put(args, "_meta", %{"trace" => "two"}),
               fn -> {:ok, %{"secret" => "must-not-run"}} end
             )

    assert %{rows: [[stored]]} =
             Repo.query!(
               "SELECT result FROM mcp_idempotency_records WHERE org_id = $1 AND tool = $2 AND idempotency_key = $3",
               [principal.org_id, "test.mutate", "meta-key"]
             )

    refute Jason.encode!(stored) =~ secret
  end

  test "demoted administrators cannot use or refresh a write grant", %{
    org: org,
    scope: scope,
    project: project
  } do
    actor = Alplus.Scope.put_project(scope, project.id)
    {grant, access_token} = issue_oauth(actor, @write_scopes)

    {:ok, refresh_token} =
      Mcp.issue_oauth_refresh_token(
        %{grant_id: grant.id, resource: OAuth.resource_uri(), scopes: @write_scopes},
        authorize?: false
      )

    refresh_secret = Ash.Resource.get_metadata(refresh_token, :token)
    {:ok, client} = Mcp.get_oauth_client(grant.oauth_client_id, authorize?: false)

    Repo.query!(
      "UPDATE memberships SET role = 'member' WHERE org_id = $1 AND user_id = $2",
      [org.id, scope.user_id]
    )

    assert {:error, :unauthenticated} = OAuth.authenticate_access_token(access_token)

    assert {:error, :invalid_grant} =
             OAuth.refresh_token(%{
               "grant_type" => "refresh_token",
               "refresh_token" => refresh_secret,
               "client_id" => client.client_id,
               "resource" => OAuth.resource_uri()
             })
  end

  test "two OAuth grants in one org independently reuse the same tool and key", %{
    actor: actor,
    grant: grant_a
  } do
    {grant_b, _token} = issue_oauth(actor, @read_scopes)
    refute grant_a.id == grant_b.id
    assert grant_a.org_id == grant_b.org_id
    assert grant_a.project_id == grant_b.project_id

    principal_a = oauth_principal(grant_a)
    principal_b = oauth_principal(grant_b)
    assert principal_a.grant_id == grant_a.id
    assert principal_b.grant_id == grant_b.id
    executions = start_supervised!({Agent, fn -> [] end})

    same_args = %{"idempotency_key" => "same-args-key", "value" => "shared"}

    assert {:ok, %{source: :a}} =
             Idempotency.run(principal_a, "test.mutate", same_args, fn ->
               Agent.update(executions, &(&1 ++ [:a]))
               {:ok, %{source: :a}}
             end)

    assert {:ok, %{source: :b}} =
             Idempotency.run(principal_b, "test.mutate", same_args, fn ->
               Agent.update(executions, &(&1 ++ [:b]))
               {:ok, %{source: :b}}
             end)

    assert {:ok, %{source: :a}} =
             Idempotency.run(principal_a, "test.mutate", same_args, fn ->
               Agent.update(executions, &(&1 ++ [:a_retry]))
               {:ok, %{source: :retry}}
             end)

    assert {:ok, %{source: :b}} =
             Idempotency.run(principal_b, "test.mutate", same_args, fn ->
               Agent.update(executions, &(&1 ++ [:b_retry]))
               {:ok, %{source: :retry}}
             end)

    assert {:ok, %{source: :a_diff}} =
             Idempotency.run(
               principal_a,
               "test.mutate",
               %{"idempotency_key" => "diff-args-key", "value" => "alpha"},
               fn ->
                 Agent.update(executions, &(&1 ++ [:a_diff]))
                 {:ok, %{source: :a_diff}}
               end
             )

    assert {:ok, %{source: :b_diff}} =
             Idempotency.run(
               principal_b,
               "test.mutate",
               %{"idempotency_key" => "diff-args-key", "value" => "bravo"},
               fn ->
                 Agent.update(executions, &(&1 ++ [:b_diff]))
                 {:ok, %{source: :b_diff}}
               end
             )

    assert {:error, %{code: :idempotency_key_conflict}} =
             Idempotency.run(
               principal_a,
               "test.mutate",
               %{"idempotency_key" => "diff-args-key", "value" => "bravo"},
               fn -> {:ok, %{source: :a_conflict}} end
             )

    assert {:error, %{code: :idempotency_key_conflict}} =
             Idempotency.run(
               principal_b,
               "test.mutate",
               %{"idempotency_key" => "diff-args-key", "value" => "alpha"},
               fn -> {:ok, %{source: :b_conflict}} end
             )

    assert Agent.get(executions, & &1) == [:a, :b, :a_diff, :b_diff]
  end

  test "cursor signing fails when its root secret is missing", %{grant: grant} do
    previous = Application.fetch_env!(:alplus, :token_signing_secret)
    Application.delete_env(:alplus, :token_signing_secret)
    on_exit(fn -> Application.put_env(:alplus, :token_signing_secret, previous) end)

    assert_raise ArgumentError, fn ->
      Cursor.encode(oauth_principal(grant), "projects.list", %{}, 0)
    end
  end

  test "rate limiter permits repeated calls", %{grant: grant} do
    principal = oauth_principal(grant)

    assert :ok = RateLimit.check(principal, "rate.repeat")
    assert :ok = RateLimit.check(principal, "rate.repeat")
  end

  test "rate limiter enforces the per-user burst limit", %{grant: grant} do
    principal = oauth_principal(grant)

    assert Enum.all?(1..20, fn _ -> RateLimit.check(principal, "rate.burst") == :ok end)
    assert {:error, %{code: :rate_limited}} = RateLimit.check(principal, "rate.burst")
  end

  test "audit metadata does not carry content or credentials", %{
    org: org,
    grant: grant,
    project: project
  } do
    principal = oauth_principal(grant)

    assert :ok =
             Audit.record(%{
               actor: principal,
               org_id: org.id,
               project_id: project.id,
               tool: "projects.list",
               correlation_id: principal.correlation_id,
               request_metadata: %{
                 "_meta" => %{"trace" => "transport-only"},
                 "markdown" => "private body",
                 "cursor" => "raw",
                 "token" => "bearer",
                 "exception" => %{"value" => "private error"},
                 "user" => %{"email" => "person@example.test"},
                 "limit" => 5
               }
             })

    assert %{rows: [[metadata, grant_id]]} =
             Alplus.Repo.query!(
               "SELECT metadata, grant_id FROM audit_logs WHERE request_id = $1 ORDER BY inserted_at DESC LIMIT 1",
               [principal.correlation_id]
             )

    refute metadata["_meta"]
    refute metadata["markdown"]
    refute metadata["cursor"]
    refute metadata["token"]
    refute metadata["exception"]
    refute metadata["user"]
    assert metadata["limit"] == 5
    assert grant_id == grant.id
  end

  test "session principals advertise only permitted tools and attribute WebMCP calls", %{
    org: org,
    scope: owner_scope,
    project: project
  } do
    previous = Application.get_env(:alplus, :mcp_adapters)
    Application.put_env(:alplus, :mcp_adapters, [Alplus.Mcp.BoundaryMutationAdapter])
    on_exit(fn -> Application.put_env(:alplus, :mcp_adapters, previous) end)

    principal = session_principal(owner_scope, org, project)

    assert principal.grant_id == nil
    assert principal.source == :session
    assert principal.access == :read_write
    refute :credential_id in principal_keys(principal)
    assert [%{name: "test.mutate"}] = Alplus.Mcp.Dispatch.tools(principal)

    assert {:ok, %{"value" => "session"}} =
             Alplus.Mcp.Dispatch.call(
               "test.mutate",
               %{
                 "project_handle" => project.id,
                 "idempotency_key" => "session-1",
                 "value" => "session"
               },
               principal
             )

    assert %{rows: [["agent", "webmcp", nil]]} =
             Alplus.Repo.query!(
               "SELECT actor_kind, transport, grant_id FROM audit_logs WHERE request_id = $1",
               [principal.correlation_id]
             )
  end

  defp issue_oauth(actor, scopes) do
    {:ok, client} = cache_client!()

    {:ok, grant} =
      Mcp.authorize_oauth_grant(
        %{
          org_id: actor.org_id,
          project_id: actor.project_id,
          user_id: actor.user_id,
          oauth_client_id: client.id,
          issuer: OAuth.issuer(),
          resource: OAuth.resource_uri(),
          scopes: scopes
        },
        actor: actor
      )

    {:ok, access_token} =
      Mcp.issue_oauth_access_token(
        %{grant_id: grant.id, resource: OAuth.resource_uri(), scopes: scopes},
        authorize?: false
      )

    token = Ash.Resource.get_metadata(access_token, :token)
    assert is_binary(token) and token != ""
    refute String.starts_with?(token, "mcred_")
    {grant, token}
  end

  defp cache_client! do
    now = DateTime.utc_now()

    Mcp.cache_oauth_client(
      %{
        issuer: OAuth.issuer(),
        client_id:
          "https://client.example/mcp-boundary-#{System.unique_integer([:positive])}.json",
        client_name: "MCP boundary test client",
        redirect_uris: ["https://client.example/oauth/callback"],
        fetched_at: now,
        expires_at: DateTime.add(now, 3600, :second)
      },
      authorize?: false
    )
  end

  defp oauth_principal(grant, scopes \\ nil) do
    Principal.from_oauth(grant, scopes || grant.scopes)
  end

  defp session_principal(scope, org, project) do
    scope
    |> Alplus.Scope.put_org(org.id, scope.role)
    |> Alplus.Scope.put_project(project.id)
    |> Principal.from_session()
  end

  defp principal_keys(%Principal{} = principal) do
    principal |> Map.from_struct() |> Map.keys()
  end
end
