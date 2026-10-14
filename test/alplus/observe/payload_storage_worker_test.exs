defmodule Alplus.Observe.PayloadStorageWorkerTest do
  use Alplus.DataCase, async: false
  use Oban.Testing, repo: Alplus.Repo

  import Alplus.OrgsFixtures

  alias Alplus.Observe.{EventWriter, PayloadStorageWorker}
  alias Alplus.Repo

  setup do
    Application.put_env(:alplus, :observe_payload_store_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:alplus, :observe_payload_store_test_pid)
      Application.delete_env(:alplus, :observe_payload_store_test_put_hook)
    end)
  end

  test "deletes an object when retention removes the event during its upload" do
    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org)
    {source, _secret} = source_fixture(scope, org, project)
    now = ~U[2026-08-30 12:00:00.000000Z]
    event_id = "err_018f2b3c4d5e7f8090123456789late1"
    key = "events/#{project.id}/#{event_id}.json"

    Application.put_env(:alplus, :observe_payload_store_test_put_hook, fn _key, _payload ->
      Repo.query!(
        "DELETE FROM error_events WHERE received_at = $1 AND event_id = $2",
        [now, event_id]
      )
    end)

    assert {:ok, %{event_id: ^event_id}} =
             EventWriter.record(overflow_event(source, event_id, now, key))

    [[outbox_id]] =
      Repo.query!(
        "SELECT id FROM observe_error_payload_outboxes WHERE event_id = $1",
        [event_id]
      ).rows

    assert :ok = perform_job(PayloadStorageWorker, %{"outbox_id" => outbox_id})
    assert_received {:observe_payload_deleted, ^key}
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM observe_error_payload_outboxes")
  end

  test "replays old outboxes with missing or terminal jobs without duplicates" do
    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org)
    {source, _secret} = source_fixture(scope, org, project)
    now = ~U[2026-08-30 12:00:00.000000Z]
    event_id = "err_018f2b3c4d5e7f8090123456789repl1"
    key = "events/#{project.id}/#{event_id}.json"

    assert {:ok, %{event_id: ^event_id}} =
             EventWriter.record(overflow_event(source, event_id, now, key))

    [[outbox_id]] =
      Repo.query!(
        "SELECT id FROM observe_error_payload_outboxes WHERE event_id = $1",
        [event_id]
      ).rows

    worker = Oban.Worker.to_string(PayloadStorageWorker)

    Repo.query!("DELETE FROM oban_jobs WHERE worker = $1 AND args ->> 'outbox_id' = $2", [
      worker,
      outbox_id
    ])

    Repo.query!("UPDATE observe_error_payload_outboxes SET inserted_at = $1", [
      DateTime.add(now, -600, :second)
    ])

    assert 1 == PayloadStorageWorker.replay_stranded(now)
    assert 0 == PayloadStorageWorker.replay_stranded(now)

    [[job_id]] =
      Repo.query!("SELECT id FROM oban_jobs WHERE worker = $1 AND args ->> 'outbox_id' = $2", [
        worker,
        outbox_id
      ]).rows

    Repo.query!("UPDATE oban_jobs SET state = 'completed', completed_at = now() WHERE id = $1", [
      job_id
    ])

    assert 1 == PayloadStorageWorker.replay_stranded(now)
    assert 0 == PayloadStorageWorker.replay_stranded(now)

    assert %{rows: [[2]]} =
             Repo.query!(
               "SELECT count(*) FROM oban_jobs WHERE worker = $1 AND args ->> 'outbox_id' = $2",
               [worker, outbox_id]
             )
  end

  defp overflow_event(source, event_id, now, key) do
    %{
      event_id: event_id,
      org_id: source.org_id,
      project_id: source.project_id,
      source_id: source.id,
      environment: source.environment,
      occurred_at: now,
      received_at: now,
      level: "error",
      sdk_name: "payload-storage-test",
      sdk_version: "1.0.0",
      exception_type: "RuntimeError",
      exception_value: "overflow",
      frames: [%{file: "/app/example.ex", function: "run", lineno: 1}],
      payload_s3_key: key,
      payload_s3_payload: "full payload"
    }
  end
end
