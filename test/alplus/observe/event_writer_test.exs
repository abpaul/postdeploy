defmodule Alplus.Observe.EventWriterTest do
  # async: false — the frame-cap test stubs `Alplus.Observe.PayloadStore.Fake`
  # through global `Application` env, same reason
  # `error_ingest_controller_test.exs` opts out of async.
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Observe.{EventWriter, PayloadStore}

  test "deduplicates a client event id and groups a repeated stack into one issue" do
    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org)
    {source, _} = source_fixture(scope, org, project)

    first = event(source, "err_018f2b3c4d5e7f8090123456789abcde")
    assert {:ok, %{new_issue?: true, issue_id: issue_id}} = EventWriter.record(first)
    assert {:ok, :duplicate} = EventWriter.record(first)

    second = %{
      first
      | event_id: "err_018f2b3c4d5e7f8090123456789abcdf",
        received_at: DateTime.add(first.received_at, 1, :second)
    }

    assert {:ok, %{new_issue?: false, issue_id: ^issue_id}} = EventWriter.record(second)

    assert %{rows: [[1, 2]]} =
             Alplus.Repo.query!("SELECT count(*), max(event_count) FROM issues WHERE id = $1", [
               issue_id
             ])

    assert %{rows: [[2]]} =
             Alplus.Repo.query!("SELECT count(*) FROM error_events WHERE issue_id = $1", [
               issue_id
             ])
  end

  test "dedup is scoped per project: two orgs posting the same event id both get accepted" do
    {org_a, scope_a} = org_fixture(scope_fixture())
    project_a = project_fixture(scope_a, org_a)
    {source_a, _} = source_fixture(scope_a, org_a, project_a)

    {org_b, scope_b} = org_fixture(scope_fixture())
    project_b = project_fixture(scope_b, org_b)
    {source_b, _} = source_fixture(scope_b, org_b, project_b)

    shared_event_id = "err_018f2b3c4d5e7f8090123456789shrd"

    event_a = event(source_a, shared_event_id)
    # `error_events` itself carries a separate PRIMARY KEY on
    # (received_at, event_id), global across tenants like the old dedup PK
    # was — out of this fix's scope (error_event_deduplications only), so
    # this test uses distinct received_at, matching two real requests, which
    # never land on the same microsecond in practice.
    event_b = %{
      event(source_b, shared_event_id)
      | received_at: DateTime.add(event_a.received_at, 1, :second)
    }

    assert {:ok, %{issue_id: issue_id_a}} = EventWriter.record(event_a)
    assert {:ok, %{issue_id: issue_id_b}} = EventWriter.record(event_b)

    refute issue_id_a == issue_id_b

    assert %{rows: [[1]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM error_events WHERE event_id = $1 AND org_id = $2",
               [shared_event_id, org_a.id]
             )

    assert %{rows: [[1]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM error_events WHERE event_id = $1 AND org_id = $2",
               [shared_event_id, org_b.id]
             )
  end

  test "dedup arbiter is (org, project, source, event_id): a retry from the SAME source still dedups" do
    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org)
    {source, _} = source_fixture(scope, org, project)

    event_id = "err_018f2b3c4d5e7f8090123456789src1"
    first = event(source, event_id)

    assert {:ok, %{new_issue?: true}} = EventWriter.record(first)
    assert {:ok, :duplicate} = EventWriter.record(first)

    assert %{rows: [[1, "source" <> _ = written_source_id]]} =
             Alplus.Repo.query!(
               "SELECT count(*), source_id FROM error_event_deduplications WHERE event_id = $1 AND project_id = $2 GROUP BY source_id",
               [event_id, project.id]
             )

    assert written_source_id == source.id
  end

  test "dedup is scoped per source in DIFFERENT projects: reusing an event_id across projects is always accepted" do
    {org, scope} = org_fixture(scope_fixture())
    subscribed_fixture(org)
    project_a = project_fixture(scope, org)
    project_b = project_fixture(scope, org)
    {source_a, _} = source_fixture(scope, org, project_a)
    {source_b, _} = source_fixture(scope, org, project_b, %{environment: "staging"})

    shared_event_id = "err_018f2b3c4d5e7f8090123456789src2"

    event_a = event(source_a, shared_event_id)

    event_b = %{
      event(source_b, shared_event_id)
      | received_at: DateTime.add(event_a.received_at, 1, :second)
    }

    assert {:ok, %{issue_id: issue_id_a, new_issue?: true}} = EventWriter.record(event_a)
    assert {:ok, %{issue_id: issue_id_b, new_issue?: true}} = EventWriter.record(event_b)

    refute issue_id_a == issue_id_b

    assert %{rows: [[2]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM error_event_deduplications WHERE event_id = $1 AND org_id = $2",
               [shared_event_id, org.id]
             )
  end

  test "dedup is scoped per source in the SAME project: two different sources reusing an event_id are both accepted, each with its own issue" do
    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org)
    {source_a, _} = source_fixture(scope, org, project)
    {source_b, _} = source_fixture(scope, org, project, %{environment: "staging"})

    shared_event_id = "err_018f2b3c4d5e7f8090123456789src3"

    event_a = event(source_a, shared_event_id)

    event_b = %{
      event(source_b, shared_event_id)
      | received_at: DateTime.add(event_a.received_at, 1, :second)
    }

    assert {:ok, %{issue_id: issue_id_a, new_issue?: true}} = EventWriter.record(event_a)
    assert {:ok, %{issue_id: issue_id_b, new_issue?: true}} = EventWriter.record(event_b)

    refute issue_id_a == issue_id_b

    assert %{rows: [[source_id_a, "production"]]} =
             Alplus.Repo.query!("SELECT source_id, environment FROM issues WHERE id = $1", [
               issue_id_a
             ])

    assert %{rows: [[source_id_b, "staging"]]} =
             Alplus.Repo.query!("SELECT source_id, environment FROM issues WHERE id = $1", [
               issue_id_b
             ])

    assert source_id_a == source_a.id
    assert source_id_b == source_b.id

    assert %{rows: dedup_rows} =
             Alplus.Repo.query!(
               "SELECT source_id FROM error_event_deduplications WHERE event_id = $1 AND project_id = $2",
               [shared_event_id, project.id]
             )

    assert Enum.sort([source_a.id, source_b.id]) == Enum.sort(List.flatten(dedup_rows))
  end

  test "reopens a resolved issue and stores an S3 overflow pointer without the payload" do
    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org)
    {source, _} = source_fixture(scope, org, project)
    first = event(source, "err_018f2b3c4d5e7f8090123456789abcd1")
    {:ok, %{issue_id: issue_id}} = EventWriter.record(first)

    Alplus.Repo.query!(
      "UPDATE issues SET status = 'resolved', resolved_at = now() WHERE id = $1",
      [issue_id]
    )

    overflow =
      Map.merge(first, %{
        event_id: "err_018f2b3c4d5e7f8090123456789abcd2",
        received_at: DateTime.add(first.received_at, 1, :second),
        payload_s3_key: "events/#{project.id}/err_018f2b3c4d5e7f8090123456789abcd2.json"
      })

    assert {:ok, %{issue_id: ^issue_id}} = EventWriter.record(overflow)

    assert %{rows: [["open", nil]]} =
             Alplus.Repo.query!("SELECT status, resolved_at FROM issues WHERE id = $1", [issue_id])

    payload_s3_key = overflow.payload_s3_key

    assert %{rows: [[^payload_s3_key]]} =
             Alplus.Repo.query!("SELECT payload_s3_key FROM error_events WHERE event_id = $1", [
               overflow.event_id
             ])
  end

  test "caps inline stored frames at 50, keeping in-app frames, while the full set stays fetchable from S3" do
    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org)
    {source, _} = source_fixture(scope, org, project)

    in_app_frames =
      for n <- 1..5 do
        %{file: "/src/app#{n}.ts", function: "run#{n}", lineno: n, in_app: true}
      end

    library_frames =
      for n <- 1..75 do
        %{file: "/node_modules/lib/mod#{n}.js", function: "helper#{n}", lineno: n}
      end

    # 5 in-app + 75 library = 80 frames, well above the 50-frame cap.
    frames = in_app_frames ++ library_frames

    event_id = "err_018f2b3c4d5e7f8090123456789cap01"
    key = "events/#{project.id}/#{event_id}.json"

    full_payload =
      Jason.encode!(%{
        "id" => event_id,
        "exception" => %{
          "stacktrace" => %{
            "frames" => Enum.map(frames, &Map.new(&1, fn {k, v} -> {to_string(k), v} end))
          }
        }
      })

    Application.put_env(:alplus, :observe_payload_store_test_gets, %{key => {:ok, full_payload}})
    on_exit(fn -> Application.delete_env(:alplus, :observe_payload_store_test_gets) end)

    overflow_event =
      source
      |> event(event_id)
      |> Map.merge(%{frames: frames, payload_s3_key: key})

    assert {:ok, %{issue_id: _issue_id}} = EventWriter.record(overflow_event)

    assert %{rows: [[stored_frames]]} =
             Alplus.Repo.query!("SELECT frames FROM error_events WHERE event_id = $1", [
               event_id
             ])

    assert length(stored_frames) == 50
    assert Enum.count(stored_frames, &(&1["in_app"] == true)) == 5

    assert Enum.all?(in_app_frames, fn frame ->
             frame.file in Enum.map(stored_frames, & &1["file"])
           end)

    assert {:ok, %{"exception" => %{"stacktrace" => %{"frames" => full_frames}}}} =
             PayloadStore.fetch(key)

    assert length(full_frames) == 80
  end

  defp event(source, event_id) do
    now = ~U[2026-08-11 13:15:00.000000Z]

    %{
      event_id: event_id,
      org_id: source.org_id,
      project_id: source.project_id,
      source_id: source.id,
      environment: source.environment,
      occurred_at: now,
      received_at: now,
      level: "error",
      sdk_name: "@alplus/sdk",
      sdk_version: "0.3.0",
      exception_type: "TypeError",
      exception_value: "Cannot read property",
      frames: [%{file: "/src/checkout.ts", function: "processOrder", lineno: 9}],
      context: %{"request" => %{"method" => "POST"}}
    }
  end
end
