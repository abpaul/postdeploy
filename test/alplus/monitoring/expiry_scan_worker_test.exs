defmodule Alplus.Monitoring.ExpiryScanWorkerTest do
  use Alplus.DataCase, async: false
  use Oban.Testing, repo: Alplus.Repo

  import Alplus.OrgsFixtures
  import Swoosh.TestAssertions

  alias Alplus.Monitoring.{ExpiryScan, ExpiryScanWorker}
  alias Alplus.Notifications.{AlertRule, DeliveryWorker}

  defmodule FixedScanner do
    @behaviour Alplus.Monitoring.ExpiryScanner

    @impl true
    def scan(_url, _opts),
      do: {:ok, %{ssl_expires_at: Process.get(:ssl_expires_at), domain_expires_at: nil}}
  end

  test "perform scans active monitors and returns ok when none fail" do
    assert {:ok, %{failures: [], warnings: _}} = ExpiryScanWorker.perform(%Oban.Job{args: %{}})
  end

  test "a renewed certificate that nears expiry warns again at the same threshold" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)

    {:ok, channel} =
      Alplus.Notifications.create_channel(
        %{org_id: org.id, type: "email", name: "expiry", config: %{"to" => "certs@example.test"}},
        owner_scope
      )

    Ash.create!(
      AlertRule,
      %{
        org_id: org.id,
        project_id: project.id,
        module: "monitor",
        trigger_type: "ssl_expiring",
        channel_id: channel.id
      },
      action: :create,
      actor: Alplus.Scope.put_project(owner_scope, project.id)
    )

    config = %{
      monitor_id: "monitor_expiry_test",
      org_id: org.id,
      project_id: project.id,
      url: "https://example.test",
      ssl_expiry_warn_days: [14],
      domain_expiry_warn_days: [14]
    }

    first_expiry = ~U[2026-10-10 00:00:00Z]
    second_expiry = ~U[2027-01-08 00:00:00Z]

    assert_expiry_email(config, first_expiry, ~U[2026-09-30 00:10:00Z])
    assert_expiry_email(config, second_expiry, ~U[2026-12-29 00:10:00Z])
  end

  defp assert_expiry_email(config, expires_at, now) do
    Process.put(:ssl_expires_at, expires_at)
    {:ok, [_warning] = warnings} = ExpiryScan.scan(config, scanner: FixedScanner, now: now)

    :ok = ExpiryScanWorker.route(warnings)
    drain_mailbox()

    for job <- all_enqueued(worker: DeliveryWorker) do
      assert :ok = perform_job(DeliveryWorker, job.args)
      Alplus.Repo.delete!(job)
    end

    assert_email_sent(to: "certs@example.test")
  end

  defp drain_mailbox do
    receive do
      {:email, _} -> drain_mailbox()
    after
      0 -> :ok
    end
  end
end
