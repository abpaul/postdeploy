defmodule Alplus.Measure.McpAdapterTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Measure.{AnalyticsEngine, Rollups}
  alias Alplus.Mcp.{Catalog, Dispatch, Error, Gateway, Principal, Schema}

  setup do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)

    {site_a, token_a} =
      source_fixture(owner_scope, org, project, %{
        type: :measure,
        name: "Site A",
        environment: "production"
      })

    {site_b, _token_b} =
      source_fixture(owner_scope, org, project, %{
        type: :measure,
        name: "Site B",
        environment: "production"
      })

    scope = Alplus.Scope.put_project(owner_scope, project.id)

    principal = %Principal{
      grant_id: Alplus.Id.generate(:mcp_oauth_grant),
      org_id: org.id,
      project_id: project.id,
      user_id: owner_scope.user_id,
      scopes: Alplus.Mcp.Scope.all(),
      source: :oauth,
      correlation_id: Alplus.Id.generate(:request)
    }

    %{
      org: org,
      project: project,
      scope: scope,
      site_a: site_a,
      site_b: site_b,
      token_a: token_a,
      principal: principal
    }
  end

  test "lists active sites with signed bounded pagination and no tokens", context do
    {site_c, _token_c} =
      source_fixture(context.scope, context.org, context.project, %{
        type: :measure,
        name: "Site C",
        environment: "production"
      })

    assert {:ok, %{sites: first, next_cursor: cursor}} =
             Dispatch.call(
               "measure.list_sites",
               %{"project_handle" => context.project.id, "limit" => 2},
               context.principal
             )

    assert length(first) == 2
    assert is_binary(cursor)

    assert {:ok, %{sites: second, next_cursor: nil}} =
             Dispatch.call(
               "measure.list_sites",
               %{"project_handle" => context.project.id, "limit" => 2, "cursor" => cursor},
               context.principal
             )

    handles = Enum.map(first ++ second, & &1.handle)
    assert Enum.sort(handles) == Enum.sort([context.site_a.id, context.site_b.id, site_c.id])
    refute inspect(first ++ second) =~ context.token_a

    assert {:ok, revoked} =
             Ash.update(context.site_b, %{}, action: :revoke, actor: context.scope)

    assert revoked.status == :revoked

    assert {:ok, %{sites: active_sites}} =
             Dispatch.call(
               "measure.list_sites",
               %{"project_handle" => context.project.id},
               context.principal
             )

    refute Enum.any?(active_sites, &(&1.handle == context.site_b.id))
  end

  test "returns source-isolated metrics and bounded breakdowns", context do
    now = DateTime.utc_now()
    project_ref = %{id: context.project.id, org_id: context.org.id}

    Rollups.record!(
      project_ref,
      context.site_a.id,
      "production",
      %{type: "pageview", path: "/only-a", hostname: "a.example"},
      %{pageviews: 3, visitors: 2, visits: 2, bounces: 1, duration_seconds: 10},
      now
    )

    Rollups.record!(
      project_ref,
      context.site_b.id,
      "production",
      %{type: "pageview", path: "/only-b", hostname: "b.example"},
      %{pageviews: 7, visitors: 6, visits: 6, bounces: 0, duration_seconds: 20},
      now
    )

    assert {:ok, %{metrics: metrics_a}} =
             Dispatch.call(
               "measure.get_metrics",
               %{
                 "project_handle" => context.project.id,
                 "source_handle" => context.site_a.id,
                 "window" => "30d"
               },
               context.principal
             )

    assert metrics_a.source.handle == context.site_a.id
    assert metrics_a.window == "30d"
    assert metrics_a.availability == "available"
    assert metrics_a.data_source == "PostgreSQL rollups"
    assert metrics_a.totals.pageviews == 3
    assert Enum.sum(Enum.map(metrics_a.trend, & &1.pageviews)) == 3
    refute inspect(metrics_a) =~ context.token_a

    assert {:ok, %{metrics: metrics_b}} =
             Dispatch.call(
               "measure.get_metrics",
               %{
                 "project_handle" => context.project.id,
                 "source_handle" => context.site_b.id,
                 "window" => "30d"
               },
               context.principal
             )

    assert metrics_b.totals.pageviews == 7

    assert {:ok, %{breakdown: breakdown}} =
             Dispatch.call(
               "measure.get_breakdown",
               %{
                 "project_handle" => context.project.id,
                 "source_handle" => context.site_a.id,
                 "window" => "30d",
                 "dimension" => "path",
                 "page" => 1
               },
               context.principal
             )

    assert breakdown.dimension == "path"
    assert [%{value: "/only-a", count: 3}] = breakdown.rows
    assert breakdown.page == 1
    assert breakdown.total_pages == 1
    refute Enum.any?(breakdown.rows, &(&1.value == "/only-b"))
  end

  test "does not expose exact MCP totals for a partial Analytics Engine window", context do
    :ok = AnalyticsEngine.Batcher.flush()
    :ok = AnalyticsEngine.DevAdapter.clear()
    on_exit(fn -> AnalyticsEngine.DevAdapter.clear() end)

    :ok =
      AnalyticsEngine.record(%{
        org_id: context.org.id,
        project_id: context.project.id,
        source_id: context.site_a.id,
        hour: DateTime.utc_now() |> DateTime.truncate(:second),
        pageviews: 3,
        visitors: 3,
        visits: 3,
        bounces: 0,
        duration_seconds: 0
      })

    :ok = AnalyticsEngine.Batcher.flush()
    Alplus.Repo.query!("ALTER TABLE analytics_hours RENAME TO analytics_hours_unavailable")

    assert {:ok, %{"result" => %{"metrics" => metrics}}} =
             Gateway.call(
               "actions.read",
               %{
                 "action" => "measure.get_metrics",
                 "arguments" => %{
                   "source_handle" => context.site_a.id,
                   "window" => "24h"
                 }
               },
               context.principal
             )

    assert metrics["availability"] == "available"
    assert metrics["headlines"]["partial?"]
    refute metrics["headlines"]["unavailable?"]
    assert metrics["totals"] == nil
    assert metrics["headlines"]["pageviews"]["value"] == nil
    assert metrics["headlines"]["pageviews"]["known_value"] == 3
    assert metrics["headlines"]["pageviews"]["coverage"] == "partial"
  end

  test "continues a breakdown with its signed cursor", context do
    now = DateTime.utc_now()
    project_ref = %{id: context.project.id, org_id: context.org.id}

    for index <- 1..9 do
      Rollups.record!(
        project_ref,
        context.site_a.id,
        "production",
        %{type: "pageview", path: "/page-#{index}", hostname: "a.example"},
        %{pageviews: index, visitors: index, visits: index, bounces: 0, duration_seconds: 1},
        now
      )
    end

    args = %{
      "project_handle" => context.project.id,
      "source_handle" => context.site_a.id,
      "window" => "30d",
      "dimension" => "path",
      "page" => 1
    }

    assert {:ok, %{breakdown: first}} =
             Dispatch.call("measure.get_breakdown", args, context.principal)

    assert first.next?
    assert is_binary(first.next_cursor)

    assert {:ok, %{breakdown: second}} =
             Dispatch.call(
               "measure.get_breakdown",
               Map.put(args, "cursor", first.next_cursor),
               context.principal
             )

    assert second.page == 2
    assert second.rows != []

    assert MapSet.disjoint?(
             MapSet.new(first.rows, & &1.value),
             MapSet.new(second.rows, & &1.value)
           )

    assert {:error, %Error{code: :invalid_cursor}} =
             Dispatch.call(
               "measure.get_breakdown",
               Map.put(args, "cursor", "tampered"),
               context.principal
             )
  end

  test "creates bounded goals and event definitions with idempotent retries", context do
    goal_args = %{
      "project_handle" => context.project.id,
      "idempotency_key" => "goal-create-1",
      "name" => "Pricing",
      "kind" => "pageview",
      "path" => "/pricing"
    }

    assert {:ok, %{goal: goal}} =
             Dispatch.call("measure.create_goal", goal_args, context.principal)

    assert goal.kind == "pageview"
    assert goal.path == "/pricing"

    assert {:ok, %{goal: ^goal}} =
             Dispatch.call("measure.create_goal", goal_args, context.principal)

    assert {:error, %Error{code: :idempotency_key_conflict}} =
             Dispatch.call(
               "measure.create_goal",
               %{goal_args | "name" => "Changed"},
               context.principal
             )

    event_args = %{
      "project_handle" => context.project.id,
      "idempotency_key" => "event-definition-1",
      "name" => "signup"
    }

    assert {:ok, %{event_definition: definition}} =
             Dispatch.call("measure.create_event_definition", event_args, context.principal)

    assert definition.name == "signup"

    assert {:ok, %{event_definition: ^definition}} =
             Dispatch.call("measure.create_event_definition", event_args, context.principal)
  end

  test "requires write access, validates arguments, and hides foreign sources", context do
    read_only = %{
      context.principal
      | scopes: Enum.filter(Alplus.Mcp.Scope.all(), &String.ends_with?(&1, ":read"))
    }

    assert {:error,
            %Error{code: :insufficient_scope, details: %{required_scopes: ["analytics:write"]}}} =
             Dispatch.call(
               "measure.create_event_definition",
               %{
                 "project_handle" => context.project.id,
                 "idempotency_key" => "read-only",
                 "name" => "signup"
               },
               read_only
             )

    assert {:error, %Error{code: :invalid_argument, details: %{field: "window"}}} =
             Dispatch.call(
               "measure.get_metrics",
               %{
                 "project_handle" => context.project.id,
                 "source_handle" => context.site_a.id,
                 "window" => "1y"
               },
               context.principal
             )

    assert {:error, %Error{code: :invalid_argument, details: %{field: "dimension"}}} =
             Dispatch.call(
               "measure.get_breakdown",
               %{
                 "project_handle" => context.project.id,
                 "source_handle" => context.site_a.id,
                 "window" => "30d",
                 "dimension" => "ip"
               },
               context.principal
             )

    {other_org, other_scope} = org_fixture(scope_fixture())
    other_project = project_fixture(other_scope, other_org)

    {other_source, _other_token} =
      source_fixture(other_scope, other_org, other_project, %{type: :measure})

    assert {:error, %Error{code: :not_found}} =
             Dispatch.call(
               "measure.get_metrics",
               %{
                 "project_handle" => context.project.id,
                 "source_handle" => other_source.id,
                 "window" => "30d"
               },
               context.principal
             )

    assert {:error, %Error{code: :not_found}} =
             Dispatch.call(
               "measure.list_sites",
               %{"project_handle" => other_project.id},
               context.principal
             )
  end

  test "publishes strict schemas for all Measure tools" do
    tools = Alplus.Measure.McpAdapter.tools()
    assert Enum.map(tools, & &1.name) == Enum.sort(Enum.map(tools, & &1.name))
    assert length(tools) == 20

    for tool <- tools do
      assert tool.input_schema.additionalProperties == false
      assert tool.output_schema.additionalProperties == false
      assert is_map(tool.input_schema.properties)
      assert is_map(tool.output_schema.properties)
    end
  end

  test "declares customer-visible destructive mutations with replay metadata" do
    tools = Map.new(Alplus.Measure.McpAdapter.tools(), &{&1.name, &1})

    for name <- [
          "measure.revoke_source",
          "measure.delete_goal",
          "measure.delete_event_definition",
          "measure.revoke_dashboard_share"
        ] do
      tool = tools[name]
      assert tool.annotations.openWorldHint
      assert tool.annotations.destructiveHint
      assert tool.annotations.idempotentHint
    end
  end

  # Regression: source_payload/1 used to emit the Ash atom `source.status`
  # (e.g. `:active`) while the declared output schema required a `"string"`.
  # `Schema.validate/2` only stringified map keys, so it compared the raw
  # atom to `type: "string"` and rejected it, and every call surfaced as
  # `invalid_result`. Driven through Gateway.call/3 (actions.publish /
  # actions.read) so the gateway's own `validate_action_result/2` step,
  # where the failure occurred, is covered end to end.
  test "returns status as a string through the actions gateway, not an atom", context do
    {:ok, _adapter, create_tool} = Catalog.get("measure.create_source")

    assert {:ok, create_result} =
             Dispatch.call(
               "measure.create_source",
               %{
                 "project_handle" => context.project.id,
                 "name" => "Gateway Site",
                 "environment" => "production",
                 "hostname" => "gateway.example.test",
                 "idempotency_key" => "gateway-create-source-001"
               },
               context.principal
             )

    assert create_result.site.status == "active"
    assert Schema.validate(create_result, create_tool.output_schema) == :ok

    {:ok, _adapter, list_tool} = Catalog.get("measure.list_sites")

    assert {:ok, list_result} =
             Dispatch.call(
               "measure.list_sites",
               %{"project_handle" => context.project.id},
               context.principal
             )

    assert Enum.all?(list_result.sites, &(&1.status == "active"))
    assert Schema.validate(list_result, list_tool.output_schema) == :ok

    {:ok, _adapter, get_tool} = Catalog.get("measure.get_site")

    assert {:ok, get_result} =
             Dispatch.call(
               "measure.get_site",
               %{
                 "project_handle" => context.project.id,
                 "source_handle" => create_result.site.handle
               },
               context.principal
             )

    assert get_result.site.status == "active"
    assert Schema.validate(get_result, get_tool.output_schema) == :ok

    # End-to-end: the gateway's own validate_action_result/2 must accept the
    # result, which is exactly where the reported `invalid_result` occurred.
    assert {:ok, %{"result" => %{"site" => gateway_site}}} =
             Gateway.call(
               "actions.publish",
               %{
                 "action" => "measure.create_source",
                 "arguments" => %{
                   "name" => "Gateway Site 2",
                   "environment" => "production",
                   "hostname" => "gateway-2.example.test"
                 },
                 "idempotency_key" => "gateway-create-source-002"
               },
               context.principal
             )

    assert gateway_site["status"] == "active"

    assert {:ok, %{"result" => %{"sites" => gateway_sites}}} =
             Gateway.call(
               "actions.read",
               %{"action" => "measure.list_sites", "arguments" => %{}},
               context.principal
             )

    assert Enum.all?(gateway_sites, &(&1["status"] == "active"))
  end
end
