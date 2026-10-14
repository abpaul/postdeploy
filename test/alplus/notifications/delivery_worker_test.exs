defmodule Alplus.Notifications.DeliveryWorkerTest do
  use Alplus.DataCase, async: false
  use Oban.Testing, repo: Alplus.Repo

  import Alplus.OrgsFixtures
  import Swoosh.TestAssertions

  alias Alplus.Notifications.{Adapters, AlertRule, DeliveryWorker}

  setup do
    previous = Application.get_env(:alplus, :notifications_req_plug)
    Application.put_env(:alplus, :notifications_req_plug, {Req.Test, Adapters})
    Req.Test.stub(Adapters, fn conn -> Plug.Conn.send_resp(conn, 204, "") end)

    on_exit(fn ->
      if previous do
        Application.put_env(:alplus, :notifications_req_plug, previous)
      else
        Application.delete_env(:alplus, :notifications_req_plug)
      end
    end)

    :ok
  end

  # `org_fixture/1` registers a user through the real action, which queues its
  # own `confirm_new_user` email. Drain the test mailbox so assertions below
  # only see delivery-worker sends.
  defp drain_mailbox do
    receive do
      {:email, _} -> drain_mailbox()
    after
      0 -> :ok
    end
  end

  # Swoosh.Adapters.Test (config/test.exs) always accepts an email send, so an
  # email channel is a simple stand-in for "the adapter call succeeded" without
  # a real network call.
  defp email_channel(org, owner_scope) do
    {:ok, channel} =
      Alplus.Notifications.create_channel(
        %{
          org_id: org.id,
          type: "email",
          name: "reclaim test",
          config: %{"to" => "alerts@example.test"}
        },
        owner_scope
      )

    channel
  end

  # The test stub below returns a client error, exercising the same permanent
  # adapter branch as an invalid or rejected provider response.
  defp unconfigured_slack_channel(org, owner_scope) do
    {:ok, channel} =
      Alplus.Notifications.create_channel(
        %{
          org_id: org.id,
          type: "slack",
          name: "broken slack",
          config: %{"webhook_url" => "https://hooks.example.test/slack"}
        },
        owner_scope
      )

    channel
  end

  defp args(org, channel, overrides \\ %{}) do
    Map.merge(
      %{
        "org_id" => org.id,
        "channel_id" => channel.id,
        "channel_type" => channel.type,
        "trigger" => "check_down",
        "subject_type" => "incident",
        "subject_id" => "inc_test",
        "repeat_index" => "0"
      },
      overrides
    )
  end

  # Seeds a delivery row exactly as `claim/2` would have left it mid-flight,
  # then lets the caller push `claim_expires_at` into the past or future to
  # simulate a crashed job versus one still legitimately in flight.
  defp insert_pending_delivery(org, channel, args, claim_expires_at) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    dedup_key = DeliveryWorker.dedup_key(args)

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO notification_deliveries
          (id, org_id, alert_rule_id, channel_id, channel_type, trigger, subject_type, subject_id,
           dedup_key, job_id, attempt, claimed_at, claim_expires_at, claim_token, status, inserted_at, updated_at)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,1,$11,$12,$13,'pending',$11,$11)
        RETURNING id
        """,
        [
          Alplus.Id.generate(:notification_delivery),
          org.id,
          nil,
          channel.id,
          channel.type,
          args["trigger"],
          args["subject_type"],
          args["subject_id"],
          dedup_key,
          "stale-crashed-job",
          now,
          claim_expires_at,
          "stale-claim-token"
        ]
      )

    id
  end

  defp status(id) do
    %{rows: [[status]]} =
      Repo.query!("SELECT status FROM notification_deliveries WHERE id = $1", [id])

    status
  end

  test "reclaims an expired pending row left by a crashed job and sends" do
    {org, owner_scope} = org_fixture(scope_fixture())
    channel = email_channel(org, owner_scope)
    drain_mailbox()
    args = args(org, channel)

    expired = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)
    id = insert_pending_delivery(org, channel, args, expired)

    assert :ok = perform_job(DeliveryWorker, args)

    assert status(id) == "sent"
    assert_email_sent(to: "alerts@example.test")
  end

  test "a sent delivery is a duplicate no-op on replay" do
    {org, owner_scope} = org_fixture(scope_fixture())
    channel = email_channel(org, owner_scope)
    drain_mailbox()
    args = args(org, channel)

    assert :ok = perform_job(DeliveryWorker, args)
    assert_email_sent(to: "alerts@example.test")

    assert :ok = perform_job(DeliveryWorker, args)

    # The replay must not reach the adapter a second time.
    refute_email_sent(to: "alerts@example.test")
  end

  test "a permanent adapter failure is skipped, not left retryable" do
    {org, owner_scope} = org_fixture(scope_fixture())
    channel = unconfigured_slack_channel(org, owner_scope)
    args = args(org, channel)
    Req.Test.stub(Adapters, fn conn -> Plug.Conn.send_resp(conn, 400, "rejected") end)

    assert {:cancel, "delivery_permanent_failure"} = perform_job(DeliveryWorker, args)

    %{rows: [[status, id]]} =
      Repo.query!(
        "SELECT status, id FROM notification_deliveries WHERE dedup_key = $1",
        [DeliveryWorker.dedup_key(args)]
      )

    assert status == "skipped"

    # A skipped row is terminal: replaying the job must not reclaim it.
    assert :ok = perform_job(DeliveryWorker, args)
    assert status(id) == "skipped"
  end

  test "a pending row with a live claim is not reclaimed" do
    {org, owner_scope} = org_fixture(scope_fixture())
    channel = email_channel(org, owner_scope)
    drain_mailbox()
    args = args(org, channel)

    live = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:microsecond)
    id = insert_pending_delivery(org, channel, args, live)

    assert :ok = perform_job(DeliveryWorker, args)

    assert status(id) == "pending"
    refute_email_sent(to: "alerts@example.test")
  end

  test "a job enqueued before trial expiry does not deliver after expiry" do
    {org, owner_scope} = org_fixture(scope_fixture())
    channel = email_channel(org, owner_scope)
    drain_mailbox()
    job_args = args(org, channel)

    assert {:ok, _job} = DeliveryWorker.enqueue(job_args)

    Alplus.Repo.query!("UPDATE organizations SET trial_ends_at = $1 WHERE id = $2", [
      ~U[2000-01-01 00:00:00.000000Z],
      org.id
    ])

    assert {:cancel, "channel_plan_gated"} = perform_job(DeliveryWorker, job_args)
    refute_email_sent(to: "alerts@example.test")

    assert [[0]] =
             Alplus.Repo.query!(
               "SELECT count(*) FROM notification_deliveries WHERE org_id = $1",
               [org.id]
             ).rows
  end

  test "enqueue and plan checks reject invalid input" do
    {org, _owner_scope} = org_fixture(scope_fixture())

    assert {:error, _} = DeliveryWorker.enqueue(%{})
    assert {:error, :plan_gated} = DeliveryWorker.check_channel_plan("webhook", "nope")
    assert {:error, :plan_gated} = DeliveryWorker.check_channel_plan("sms", org.id)
    assert :ok = DeliveryWorker.check_channel_plan("email", org.id)
    assert {:cancel, "invalid_notification_args"} = perform_job(DeliveryWorker, %{})

    assert {:cancel, "channel_not_found"} =
             perform_job(DeliveryWorker, %{
               "org_id" => "org_missing",
               "channel_id" => "chan_missing",
               "channel_type" => "email",
               "trigger" => "down",
               "subject_type" => "monitor",
               "subject_id" => "mon_x",
               "repeat_index" => "0"
             })
  end

  test "preserves referenced channel and rule history while unused items remain deletable" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    project_scope = Alplus.Scope.put_project(owner_scope, project.id)
    channel = email_channel(org, owner_scope)

    rule =
      Ash.create!(
        AlertRule,
        %{
          org_id: org.id,
          project_id: project.id,
          module: "monitor",
          trigger_type: "check_down",
          channel_id: channel.id
        },
        action: :create,
        actor: project_scope
      )

    delivery_args = args(org, channel, %{"alert_rule_id" => rule.id})
    assert :ok = perform_job(DeliveryWorker, delivery_args)

    assert {:error, :deliveries_exist} =
             Alplus.Notifications.delete_channel(channel.id, owner_scope)

    assert {:error, :deliveries_exist} =
             Alplus.Notifications.delete_rule(rule.id, project_scope)

    {:ok, unused_channel} =
      Alplus.Notifications.create_channel(
        %{
          org_id: org.id,
          type: "email",
          name: "Unused channel",
          config: %{"to" => "unused@example.test"}
        },
        owner_scope
      )

    unused_rule =
      Ash.create!(
        AlertRule,
        %{
          org_id: org.id,
          project_id: project.id,
          module: "monitor",
          trigger_type: "check_recovered",
          channel_id: unused_channel.id
        },
        action: :create,
        actor: project_scope
      )

    assert :ok = Alplus.Notifications.delete_rule(unused_rule.id, project_scope)
    assert :ok = Alplus.Notifications.delete_channel(unused_channel.id, owner_scope)

    assert %{rows: [[1]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM notification_deliveries WHERE channel_id = $1 AND alert_rule_id = $2",
               [channel.id, rule.id]
             )
  end
end
