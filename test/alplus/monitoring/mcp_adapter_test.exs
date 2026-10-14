defmodule Alplus.Monitoring.McpAdapterTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Mcp.{Dispatch, Error, Principal}
  alias Alplus.Monitoring.MonitorCreator

  setup do
    {org, owner_scope} = org_fixture(scope_fixture())

    project =
      project_fixture(owner_scope, org, %{
        slug: "monitor-mcp-#{System.unique_integer([:positive])}"
      })

    {:ok,
     org: org,
     project: project,
     scope: Alplus.Scope.put_project(owner_scope, project.id),
     principal: %Principal{
       grant_id: Alplus.Id.generate(:mcp_oauth_grant),
       org_id: org.id,
       project_id: project.id,
       user_id: owner_scope.user_id,
       scopes: Alplus.Mcp.Scope.all(),
       source: :oauth,
       correlation_id: Alplus.Id.generate(:request)
     }}
  end

  test "creates, reads, updates, pauses, and lists a monitor through MCP", context do
    create_args = %{
      "project_handle" => context.project.id,
      "name" => "API health",
      "type" => "http",
      "url" => "https://example.test/health",
      "interval_seconds" => 300,
      "timeout_seconds" => 10,
      "idempotency_key" => "create-api"
    }

    assert {:ok, %{monitor: monitor}} =
             Dispatch.call("monitor.create", create_args, context.principal)

    assert monitor.name == "API health"
    assert monitor.type == "http"
    assert monitor.config["url"] == "https://example.test/health"
    assert monitor.config["expected_status"] == %{"kind" => "range", "min" => 200, "max" => 399}
    assert monitor.config["keyword_match"] == nil
    refute Map.has_key?(monitor.config, "body")

    assert {:ok, %{monitor: %{handle: handle}}} =
             Dispatch.call(
               "monitor.get",
               %{"project_handle" => context.project.id, "monitor_handle" => monitor.handle},
               context.principal
             )

    assert handle == monitor.handle

    assert {:ok, %{monitor: updated}} =
             Dispatch.call(
               "monitor.update",
               %{
                 "project_handle" => context.project.id,
                 "monitor_handle" => monitor.handle,
                 "name" => "API health updated",
                 "url" => "https://example.test/ready",
                 "interval_seconds" => 300,
                 "idempotency_key" => "update-api"
               },
               context.principal
             )

    assert updated.name == "API health updated"
    assert updated.config["url"] == "https://example.test/ready"

    assert {:ok, %{monitor: %{status: "paused"}}} =
             Dispatch.call(
               "monitor.pause",
               %{
                 "project_handle" => context.project.id,
                 "monitor_handle" => monitor.handle,
                 "paused" => true,
                 "idempotency_key" => "pause-api"
               },
               context.principal
             )

    assert {:ok, %{monitor: %{status: "active"}}} =
             Dispatch.call(
               "monitor.pause",
               %{
                 "project_handle" => context.project.id,
                 "monitor_handle" => monitor.handle,
                 "paused" => false,
                 "idempotency_key" => "resume-api"
               },
               context.principal
             )

    assert {:ok, %{monitors: monitors, next_cursor: nil}} =
             Dispatch.call(
               "monitor.list",
               %{"project_handle" => context.project.id, "limit" => 10},
               context.principal
             )

    assert Enum.any?(monitors, &(&1.handle == monitor.handle and &1.status == "active"))
  end

  test "reissues heartbeat secret once and does not expose hash on reads", context do
    assert {:ok, %{monitor: monitor, heartbeat_secret: initial_secret}} =
             Dispatch.call(
               "monitor.create",
               %{
                 "project_handle" => context.project.id,
                 "name" => "Heartbeat",
                 "type" => "heartbeat",
                 "interval_seconds" => 300,
                 "grace_period_seconds" => 60,
                 "idempotency_key" => "heartbeat-create-reissue"
               },
               context.principal
             )

    assert String.starts_with?(initial_secret, "hb_")

    monitor_id = monitor.handle

    assert {:ok, %{monitor_handle: ^monitor_id, heartbeat_secret: secret}} =
             Dispatch.call(
               "monitor.reissue_heartbeat_secret",
               %{
                 "project_handle" => context.project.id,
                 "monitor_handle" => monitor.handle,
                 "idempotency_key" => "heartbeat-reissue"
               },
               context.principal
             )

    assert String.starts_with?(secret, "hb_")
    refute secret == initial_secret

    assert {:ok, %{monitor_handle: ^monitor_id, heartbeat_secret: ^secret}} =
             Dispatch.call(
               "monitor.reissue_heartbeat_secret",
               %{
                 "project_handle" => context.project.id,
                 "monitor_handle" => monitor.handle,
                 "idempotency_key" => "heartbeat-reissue"
               },
               context.principal
             )

    assert {:ok, %{monitor: payload}} =
             Dispatch.call(
               "monitor.get",
               %{"project_handle" => context.project.id, "monitor_handle" => monitor.handle},
               context.principal
             )

    refute inspect(payload) =~ "heartbeat_token"
    refute inspect(payload) =~ secret
    refute inspect(payload) =~ Base.encode16(:crypto.hash(:sha256, secret), case: :lower)
  end

  test "deletes a monitor and its scheduler-visible resource idempotently", context do
    assert {:ok, %{monitor: monitor}} =
             Dispatch.call(
               "monitor.create",
               %{
                 "project_handle" => context.project.id,
                 "name" => "Delete me",
                 "type" => "http",
                 "url" => "https://example.test/delete",
                 "interval_seconds" => 300,
                 "timeout_seconds" => 10,
                 "idempotency_key" => "delete-create"
               },
               context.principal
             )

    delete_args = %{
      "project_handle" => context.project.id,
      "monitor_handle" => monitor.handle,
      "idempotency_key" => "delete-monitor"
    }

    monitor_handle = monitor.handle

    assert {:ok, %{deleted: true, monitor_handle: ^monitor_handle}} =
             Dispatch.call("monitor.delete", delete_args, context.principal)

    assert {:ok, %{deleted: true, monitor_handle: ^monitor_handle}} =
             Dispatch.call("monitor.delete", delete_args, context.principal)

    assert {:error, %Error{code: :not_found}} =
             Dispatch.call(
               "monitor.get",
               %{"project_handle" => context.project.id, "monitor_handle" => monitor.handle},
               context.principal
             )
  end

  test "publishes destructive delete and secret reissue annotations" do
    tools = Map.new(Alplus.Monitoring.McpAdapter.tools(), &{&1.name, &1})

    assert tools["monitor.delete"].annotations[:destructiveHint]
    assert tools["monitor.delete"].requires_access == :read_write
    assert tools["monitor.reissue_heartbeat_secret"].requires_access == :read_write
    assert tools["monitor.reissue_heartbeat_secret"].annotations[:idempotentHint]
    create = tools["monitor.create"]
    assert create.description =~ "setup secret exactly once"
    assert length(create.output_schema.oneOf) == 2

    heartbeat_output =
      Enum.find(create.output_schema.oneOf, &Map.has_key?(&1.properties, :heartbeat_secret))

    assert "heartbeat_secret" in heartbeat_output.required
  end

  test "creates and returns safe payloads for every monitor type", context do
    type_configs = [
      {"http", %{"url" => "https://example.test", "timeout_seconds" => 10}},
      {"keyword",
       %{
         "url" => "https://example.test",
         "keyword" => "ready",
         "timeout_seconds" => 10
       }},
      {"heartbeat", %{"grace_period_seconds" => 60}},
      {"tcp", %{"hostname" => "example.test", "port" => 443, "timeout_seconds" => 10}},
      {"dns",
       %{
         "hostname" => "example.test",
         "record_type" => "A",
         "expected_values" => ["192.0.2.1"],
         "match_mode" => "all"
       }}
    ]

    for {type, config} <- type_configs do
      args =
        Map.merge(
          %{
            "project_handle" => context.project.id,
            "name" => "MCP #{type}",
            "type" => type,
            "interval_seconds" => 300,
            "idempotency_key" => "create-#{type}"
          },
          config
        )

      assert {:ok, result} = Dispatch.call("monitor.create", args, context.principal)
      assert %{monitor: monitor} = result

      assert monitor.type == type
      assert is_map(monitor.config)
      refute Map.has_key?(monitor.config, "heartbeat_token_hash")

      if type == "heartbeat" do
        assert is_binary(result.heartbeat_secret)
        assert String.starts_with?(result.heartbeat_secret, "hb_")
      else
        refute Map.has_key?(result, :heartbeat_secret)
      end
    end
  end

  test "returns heartbeat setup secret only on create and records scoped heartbeats", context do
    create_args = %{
      "project_handle" => context.project.id,
      "name" => "Cron",
      "type" => "heartbeat",
      "interval_seconds" => 300,
      "grace_period_seconds" => 60,
      "idempotency_key" => "heartbeat-create"
    }

    assert {:ok, %{monitor: monitor, heartbeat_secret: secret}} =
             Dispatch.call("monitor.create", create_args, context.principal)

    assert String.starts_with?(secret, "hb_")

    assert {:ok, %{monitor: payload}} =
             Dispatch.call(
               "monitor.get",
               %{"project_handle" => context.project.id, "monitor_handle" => monitor.handle},
               context.principal
             )

    assert {:ok, %{monitors: monitors}} =
             Dispatch.call(
               "monitor.list",
               %{"project_handle" => context.project.id, "limit" => 10},
               context.principal
             )

    listed = Enum.find(monitors, &(&1.handle == monitor.handle))

    refute inspect(payload) =~ secret
    refute inspect(payload) =~ "heartbeat_token"
    refute inspect(payload) =~ Base.encode16(:crypto.hash(:sha256, secret), case: :lower)
    refute inspect(listed) =~ secret
    refute inspect(listed) =~ "heartbeat_token"
    refute inspect(listed) =~ Base.encode16(:crypto.hash(:sha256, secret), case: :lower)

    assert %{rows: [[metadata]]} =
             Alplus.Repo.query!(
               "SELECT metadata FROM audit_logs WHERE request_id = $1 AND action = 'monitor.create' ORDER BY inserted_at DESC LIMIT 1",
               [context.principal.correlation_id]
             )

    refute Jason.encode!(metadata) =~ secret
    refute Jason.encode!(metadata) =~ "heartbeat_token"
    refute Jason.encode!(metadata) =~ "heartbeat_token_hash"

    assert {:ok, %{accepted: true, state: "finish"}} =
             Dispatch.call(
               "monitor.heartbeat",
               %{
                 "project_handle" => context.project.id,
                 "monitor_handle" => monitor.handle,
                 "state" => "finish",
                 "idempotency_key" => "heartbeat-finish"
               },
               context.principal
             )

    assert %{rows: [[1]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM monitor_checks WHERE monitor_id = $1 AND status = 'up'",
               [monitor.handle]
             )
  end

  test "requires write access for mutations and hides another organization's monitors", context do
    read_only = %{
      context.principal
      | scopes: Enum.filter(Alplus.Mcp.Scope.all(), &String.ends_with?(&1, ":read"))
    }

    assert {:error,
            %Error{code: :insufficient_scope, details: %{required_scopes: ["monitor:write"]}}} =
             Dispatch.call(
               "monitor.pause",
               %{
                 "project_handle" => context.project.id,
                 "monitor_handle" => "mon_missing",
                 "paused" => true,
                 "idempotency_key" => "read-only-pause"
               },
               read_only
             )

    {other_org, other_scope} = org_fixture(scope_fixture())
    other_project = project_fixture(other_scope, other_org)

    assert {:error, %Error{code: :not_found}} =
             Dispatch.call(
               "monitor.list",
               %{"project_handle" => other_project.id},
               context.principal
             )
  end

  test "lists checks and incidents with bounded empty pages", context do
    assert {:ok, %{monitor: monitor}} =
             MonitorCreator.create(
               %{
                 org_id: context.org.id,
                 project_id: context.project.id,
                 name: "API",
                 type: "http"
               },
               %{
                 url: "https://example.test",
                 expected_status: %{"kind" => "range", "min" => 200, "max" => 399},
                 interval_seconds: 300,
                 timeout_seconds: 10
               },
               context.scope
             )

    for tool <- ["monitor.list_checks", "monitor.list_incidents"] do
      assert {:ok, result} =
               Dispatch.call(
                 tool,
                 %{
                   "project_handle" => context.project.id,
                   "monitor_handle" => monitor.id,
                   "limit" => 10
                 },
                 context.principal
               )

      key = if tool == "monitor.list_checks", do: :checks, else: :incidents
      assert Map.fetch!(result, key) == []
      assert result.next_cursor == nil
    end
  end

  test "publishes strict output schemas for monitor payloads" do
    for tool <- Alplus.Monitoring.McpAdapter.tools() do
      assert tool.output_schema.additionalProperties == false

      case tool.output_schema.properties[:monitor] do
        nil -> :ok
        monitor -> assert monitor.additionalProperties == false
      end
    end
  end

  test "publishes strict type-specific monitor create branches" do
    tool = Enum.find(Alplus.Monitoring.McpAdapter.tools(), &(&1.name == "monitor.create"))
    branches = tool.input_schema.oneOf

    expected_properties = %{
      "http" =>
        ~w(environment idempotency_key interval_seconds name project_handle retry_interval_seconds timeout_seconds type url),
      "keyword" =>
        ~w(environment idempotency_key interval_seconds keyword name project_handle retry_interval_seconds timeout_seconds type url),
      "heartbeat" =>
        ~w(environment grace_period_seconds idempotency_key interval_seconds name project_handle type),
      "tcp" =>
        ~w(environment hostname idempotency_key interval_seconds name port project_handle retry_interval_seconds timeout_seconds type),
      "dns" =>
        ~w(environment expected_values hostname idempotency_key interval_seconds match_mode name project_handle record_type retry_interval_seconds type)
    }

    assert Enum.sort(Enum.map(branches, & &1.properties.type.const)) ==
             Enum.sort(Map.keys(expected_properties))

    for branch <- branches do
      type = branch.properties.type.const

      property_names =
        branch.properties |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()

      assert branch.additionalProperties == false
      assert property_names == expected_properties[type]
      assert Enum.all?(branch.required, &Map.has_key?(branch.properties, String.to_atom(&1)))
    end
  end
end
