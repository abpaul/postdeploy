defmodule Alplus.Monitoring.ExpiryScanTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Monitoring.ExpiryScan
  alias Alplus.Monitoring.{HttpConfig, Monitor}
  alias Alplus.Scope

  defmodule Scanner do
    @behaviour Alplus.Monitoring.ExpiryScanner

    @impl true
    def scan(url, _opts) do
      send(self(), {:scanned, url})

      {:ok,
       %{
         ssl_expires_at: ~U[2026-08-25 12:00:00Z],
         domain_expires_at: ~U[2026-08-18 12:00:00Z]
       }}
    end
  end

  defmodule FailingScanner do
    @behaviour Alplus.Monitoring.ExpiryScanner

    @impl true
    def scan(_url, _opts), do: {:error, :timeout}
  end

  defmodule SlowScanner do
    @behaviour Alplus.Monitoring.ExpiryScanner

    @impl true
    def scan(_url, timeout: 5_000) do
      receive do
      after
        5_100 ->
          {:ok,
           %{
             ssl_expires_at: ~U[2026-08-25 12:00:00Z],
             domain_expires_at: nil
           }}
      end
    end
  end

  defmodule TimeoutScanner do
    @behaviour Alplus.Monitoring.ExpiryScanner

    @impl true
    def scan("https://slow.example.test", _opts) do
      receive do
      after
        100 -> {:ok, %{ssl_expires_at: ~U[2026-08-25 12:00:00Z], domain_expires_at: nil}}
      end
    end

    def scan(_url, _opts) do
      {:ok, %{ssl_expires_at: ~U[2026-08-25 12:00:00Z], domain_expires_at: nil}}
    end
  end

  @config %{
    monitor_id: "mon_01j00000000000000000000000",
    org_id: "org_01j00000000000000000000000",
    project_id: "proj_01j00000000000000000000000",
    url: "https://status.example.test",
    ssl_expiry_warn_days: nil,
    domain_expiry_warn_days: nil
  }

  test "creates stable ssl and domain warning events at the configured thresholds" do
    assert {:ok, warnings} =
             ExpiryScan.scan(@config, scanner: Scanner, now: ~U[2026-08-11 08:00:00Z])

    assert_receive {:scanned, "https://status.example.test"}

    assert Enum.map(warnings, &{&1.kind, &1.threshold_days, &1.days_remaining}) == [
             {:ssl_expiring, 14, 14},
             {:domain_expiring, 14, 7},
             {:domain_expiring, 7, 7}
           ]

    assert Enum.all?(warnings, &String.starts_with?(&1.idempotency_key, "expiry:"))

    assert {:ok, repeated} =
             ExpiryScan.scan(@config, scanner: Scanner, now: ~U[2026-08-11 08:00:00Z])

    assert Enum.map(repeated, & &1.idempotency_key) == Enum.map(warnings, & &1.idempotency_key)
  end

  test "uses each config's custom thresholds and does not warn before a threshold" do
    config = %{@config | ssl_expiry_warn_days: [7], domain_expiry_warn_days: [1]}

    assert {:ok, []} = ExpiryScan.scan(config, scanner: Scanner, now: ~U[2026-08-11 08:00:00Z])
  end

  test "returns scanner failures without an outbound fallback" do
    assert {:error, :timeout} = ExpiryScan.scan(@config, scanner: FailingScanner)
  end

  test "rejects an incomplete maintenance row" do
    assert {:error, :invalid_monitor_config} =
             ExpiryScan.scan(%{url: "https://example.test"}, scanner: Scanner)
  end

  @tag timeout: 10_000
  test "returns warnings when an active scan takes longer than five seconds" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)

    monitor =
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "http", name: "Expiry"},
        action: :create,
        actor: scope
      )

    Ash.create!(
      HttpConfig,
      %{
        monitor_id: monitor.id,
        org_id: org.id,
        url: "https://status.example.test",
        expected_status: %{"kind" => "range", "min" => 200, "max" => 399},
        interval_seconds: 300,
        timeout_seconds: 10
      },
      action: :create,
      actor: scope
    )

    assert %{failures: [], warnings: [warning | _]} =
             ExpiryScan.scan_active(scanner: SlowScanner, now: ~U[2026-08-11 08:00:00Z])

    assert warning.kind == :ssl_expiring
    assert warning.monitor_id == monitor.id
  end

  test "keeps healthy warnings when another active scan times out" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)

    healthy_monitor =
      active_http_monitor_fixture(scope, org, project, "https://healthy.example.test")

    slow_monitor = active_http_monitor_fixture(scope, org, project, "https://slow.example.test")

    result =
      ExpiryScan.scan_active(
        scanner: TimeoutScanner,
        task_timeout: 25,
        now: ~U[2026-08-11 08:00:00Z]
      )

    assert Enum.any?(result.warnings, &(&1.monitor_id == healthy_monitor.id))
    assert Enum.any?(result.failures, &(elem(&1, 0) == slow_monitor.id))
  end

  defp active_http_monitor_fixture(scope, org, project, url) do
    monitor =
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "http", name: "Expiry #{url}"},
        action: :create,
        actor: scope
      )

    Ash.create!(
      HttpConfig,
      %{
        monitor_id: monitor.id,
        org_id: org.id,
        url: url,
        expected_status: %{"kind" => "range", "min" => 200, "max" => 399},
        interval_seconds: 300,
        timeout_seconds: 10
      },
      action: :create,
      actor: scope
    )

    monitor
  end
end
