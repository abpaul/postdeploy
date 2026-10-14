defmodule Alplus.Monitoring.MonitorFormAttrsTest do
  use ExUnit.Case, async: true

  alias Alplus.Monitoring.MonitorFormAttrs

  @scope %{org_id: "organization_test", project_id: "project_test"}

  test "monitor_create_attrs rejects a URL over the DB's 2048-byte cap" do
    too_long_url = "https://example.test/" <> String.duplicate("a", 2048)

    assert {:error, _reason} =
             MonitorFormAttrs.monitor_create_attrs(
               %{"name" => "API", "type" => "http"},
               %{"url" => too_long_url, "interval_seconds" => "300", "timeout_seconds" => "10"},
               @scope
             )
  end

  test "monitor_create_attrs rejects malformed and userinfo HTTP URLs" do
    for url <- ["example.test/health", "https://user:pass@example.test/health"] do
      assert {:error, :invalid_config} =
               MonitorFormAttrs.monitor_create_attrs(
                 %{"name" => "API", "type" => "http"},
                 %{"url" => url, "interval_seconds" => "300"},
                 @scope
               )
    end
  end

  test "heartbeat attrs accept interval or cron schedules and reject malformed cron" do
    assert {:ok, _, %{interval_seconds: 300, cron_expression: nil}} =
             MonitorFormAttrs.monitor_create_attrs(
               %{"name" => "HB", "type" => "heartbeat"},
               %{"interval_seconds" => "300"},
               @scope
             )

    assert {:ok, _, %{interval_seconds: nil, cron_expression: "*/5 * * * *"}} =
             MonitorFormAttrs.monitor_create_attrs(
               %{"name" => "HB", "type" => "heartbeat"},
               %{"cron_expression" => "*/5 * * * *"},
               @scope
             )

    assert {:error, :invalid_schedule} =
             MonitorFormAttrs.monitor_create_attrs(
               %{"name" => "HB", "type" => "heartbeat"},
               %{"cron_expression" => "not cron"},
               @scope
             )
  end

  test "monitor_create_attrs enforces timeout and heartbeat grace bounds" do
    assert {:error, :invalid_config} =
             MonitorFormAttrs.monitor_create_attrs(
               %{"name" => "API", "type" => "http"},
               %{
                 "url" => "https://example.test",
                 "interval_seconds" => "300",
                 "timeout_seconds" => "61"
               },
               @scope
             )

    assert {:error, :invalid_config} =
             MonitorFormAttrs.monitor_create_attrs(
               %{"name" => "HB", "type" => "heartbeat"},
               %{"interval_seconds" => "300", "grace_period_seconds" => "86401"},
               @scope
             )
  end

  test "monitor_create_attrs rejects a TCP port outside 1..65535" do
    assert {:error, _reason} =
             MonitorFormAttrs.monitor_create_attrs(
               %{"name" => "DB", "type" => "tcp"},
               %{
                 "hostname" => "db.example.test",
                 "port" => "99999",
                 "interval_seconds" => "300",
                 "timeout_seconds" => "10"
               },
               @scope
             )
  end

  test "create and update reject invalid types and configs" do
    assert {:error, :invalid_monitor} =
             MonitorFormAttrs.monitor_create_attrs("bad", %{}, @scope)

    assert {:error, :invalid_monitor} =
             MonitorFormAttrs.monitor_update_attrs("bad", %{}, %{})

    assert {:error, _} =
             MonitorFormAttrs.monitor_create_attrs(
               %{"name" => "X", "type" => "http"},
               %{"url" => "", "interval_seconds" => "60", "timeout_seconds" => "5"},
               @scope
             )

    assert {:error, _} =
             MonitorFormAttrs.monitor_create_attrs(
               %{"name" => "X", "type" => "keyword"},
               %{
                 "url" => "https://x.test",
                 "keyword" => "",
                 "interval_seconds" => "60",
                 "timeout_seconds" => "5"
               },
               @scope
             )

    assert {:error, _} =
             MonitorFormAttrs.monitor_create_attrs(
               %{"name" => "X", "type" => "tcp"},
               %{
                 "hostname" => "",
                 "port" => "80",
                 "interval_seconds" => "60",
                 "timeout_seconds" => "5"
               },
               @scope
             )

    assert {:error, _} =
             MonitorFormAttrs.monitor_create_attrs(
               %{"name" => "X", "type" => "nope"},
               %{"interval_seconds" => "60"},
               @scope
             )

    assert {:error, :invalid_integer} = MonitorFormAttrs.positive_integer("nope")
    assert {:ok, 3} = MonitorFormAttrs.positive_integer(3)
    assert {:error, :invalid_integer} = MonitorFormAttrs.positive_integer(0)
  end

  test "SLO targets are optional, normalized to ratios, and validated" do
    assert {:ok, 0.999} = MonitorFormAttrs.parse_slo_target("99.9%")
    assert {:ok, 0.999} = MonitorFormAttrs.parse_slo_target("0.999")
    assert {:ok, nil} = MonitorFormAttrs.parse_slo_target("")
    assert {:error, :invalid_slo_target} = MonitorFormAttrs.parse_slo_target("101%")
    assert {:error, :invalid_slo_target} = MonitorFormAttrs.parse_slo_target("0")

    assert {:ok, attrs, _config} =
             MonitorFormAttrs.monitor_create_attrs(
               %{"name" => "API", "type" => "http", "slo_target" => "0.999"},
               %{"url" => "https://example.test", "interval_seconds" => "300"},
               @scope
             )

    assert attrs.slo_target == 0.999

    assert {:ok, %{slo_target: nil}, _config} =
             MonitorFormAttrs.monitor_update_attrs(
               %{"name" => "API", "slo_target" => ""},
               %{"url" => "https://example.test", "interval_seconds" => "300"},
               "http"
             )
  end

  test "update attrs cover every type and the invalid config clauses" do
    assert {:ok, %{name: "API", environment: "staging"}, %{url: "https://x.test"}} =
             MonitorFormAttrs.monitor_update_attrs(
               %{"name" => "API", "environment" => "staging"},
               %{"url" => "https://x.test", "interval_seconds" => "60"},
               "http"
             )

    assert {:error, :invalid_config} =
             MonitorFormAttrs.monitor_update_attrs(
               %{"name" => "API"},
               %{"url" => "", "interval_seconds" => "60"},
               "http"
             )

    assert {:ok, _, %{keyword_match: %{"value" => "ok"}}} =
             MonitorFormAttrs.monitor_update_attrs(
               %{"name" => "KW"},
               %{"url" => "https://x.test", "keyword" => "ok", "interval_seconds" => "60"},
               "keyword"
             )

    assert {:error, :invalid_config} =
             MonitorFormAttrs.monitor_update_attrs(
               %{"name" => "KW"},
               %{"url" => "https://x.test", "interval_seconds" => "60"},
               "keyword"
             )

    assert {:ok, _, %{interval_seconds: 60}} =
             MonitorFormAttrs.monitor_update_attrs(
               %{"name" => "HB"},
               %{"interval_seconds" => "60"},
               "heartbeat"
             )

    assert {:ok, _, %{interval_seconds: nil, cron_expression: "0 * * * *"}} =
             MonitorFormAttrs.monitor_update_attrs(
               %{"name" => "HB"},
               %{"cron_expression" => "0 * * * *"},
               "heartbeat"
             )

    assert {:ok, _, %{hostname: "db.test", port: 5432}} =
             MonitorFormAttrs.monitor_update_attrs(
               %{"name" => "TCP"},
               %{"hostname" => "db.test", "port" => "5432", "interval_seconds" => "60"},
               "tcp"
             )

    assert {:error, :invalid_config} =
             MonitorFormAttrs.monitor_update_attrs(
               %{"name" => "TCP"},
               %{"hostname" => "", "interval_seconds" => "60"},
               "tcp"
             )

    assert {:ok, _, %{record_type: "A"}} =
             MonitorFormAttrs.monitor_update_attrs(
               %{"name" => "DNS"},
               %{
                 "hostname" => "edge.test",
                 "record_type" => "A",
                 "expected_values" => "1.2.3.4",
                 "interval_seconds" => "60"
               },
               "dns"
             )

    assert {:error, :invalid_config} =
             MonitorFormAttrs.monitor_update_attrs(
               %{"name" => "DNS"},
               %{"hostname" => "", "interval_seconds" => "60"},
               "dns"
             )

    assert {:error, :invalid_config} =
             MonitorFormAttrs.monitor_update_attrs(
               %{"name" => "X"},
               %{"interval_seconds" => "60"},
               "nope"
             )

    assert {:ok, %{environment: nil}, _} =
             MonitorFormAttrs.monitor_update_attrs(
               %{"name" => "API", "environment" => ""},
               %{"url" => "https://x.test", "interval_seconds" => "60"},
               "http"
             )

    assert {:error, :invalid_config} =
             MonitorFormAttrs.monitor_create_attrs(
               %{"name" => "X", "type" => "keyword"},
               %{
                 "url" => "https://x.test",
                 "keyword" => String.duplicate("k", 901),
                 "interval_seconds" => "60",
                 "timeout_seconds" => "5"
               },
               @scope
             )

    assert {:error, :invalid_config} =
             MonitorFormAttrs.monitor_create_attrs(
               %{"name" => "X", "type" => "tcp"},
               %{
                 "hostname" => String.duplicate("h", 2049),
                 "port" => "80",
                 "interval_seconds" => "60",
                 "timeout_seconds" => "5"
               },
               @scope
             )

    assert {:ok, %{environment: "prod"}, _} =
             MonitorFormAttrs.monitor_create_attrs(
               %{"name" => "API", "type" => "http", "environment" => "prod"},
               %{
                 "url" => "https://example.test/health",
                 "interval_seconds" => "300",
                 "timeout_seconds" => "10"
               },
               @scope
             )

    assert {:ok, _, %{timeout_seconds: 5}} =
             MonitorFormAttrs.monitor_create_attrs(
               %{"name" => "DB", "type" => "tcp"},
               %{
                 "hostname" => "db.example.test",
                 "port" => "5432",
                 "interval_seconds" => "60",
                 "timeout_seconds" => "5"
               },
               @scope
             )
  end

  test "monitor_create_attrs accepts a URL and port within bounds" do
    assert {:ok, _monitor_attrs, _config_attrs} =
             MonitorFormAttrs.monitor_create_attrs(
               %{"name" => "API", "type" => "http"},
               %{
                 "url" => "https://example.test/health",
                 "interval_seconds" => "300",
                 "timeout_seconds" => "10"
               },
               @scope
             )
  end

  test "monitor_create_attrs accepts an empty DNS expected_values list (resolvability mode)" do
    assert {:ok, _monitor_attrs, config_attrs} =
             MonitorFormAttrs.monitor_create_attrs(
               %{"name" => "Edge", "type" => "dns"},
               %{
                 "hostname" => "edge.example.test",
                 "record_type" => "A",
                 "expected_values" => "",
                 "interval_seconds" => "300"
               },
               @scope
             )

    assert config_attrs.expected_values == []
    assert config_attrs.match_mode == :all
  end

  test "monitor_create_attrs defaults DNS match_mode to :all when absent" do
    assert {:ok, _monitor_attrs, config_attrs} =
             MonitorFormAttrs.monitor_create_attrs(
               %{"name" => "Edge", "type" => "dns"},
               %{
                 "hostname" => "edge.example.test",
                 "record_type" => "A",
                 "expected_values" => "1.2.3.4",
                 "interval_seconds" => "300"
               },
               @scope
             )

    assert config_attrs.match_mode == :all
  end

  test "monitor_create_attrs accepts DNS match_mode :any" do
    assert {:ok, _monitor_attrs, config_attrs} =
             MonitorFormAttrs.monitor_create_attrs(
               %{"name" => "Edge", "type" => "dns"},
               %{
                 "hostname" => "edge.example.test",
                 "record_type" => "A",
                 "expected_values" => "1.2.3.4, 5.6.7.8",
                 "match_mode" => "any",
                 "interval_seconds" => "300"
               },
               @scope
             )

    assert config_attrs.match_mode == :any
    assert config_attrs.expected_values == ["1.2.3.4", "5.6.7.8"]
  end

  test "monitor_create_attrs rejects an invalid DNS match_mode instead of atomizing it" do
    assert {:error, :invalid_dns_values} =
             MonitorFormAttrs.monitor_create_attrs(
               %{"name" => "Edge", "type" => "dns"},
               %{
                 "hostname" => "edge.example.test",
                 "record_type" => "A",
                 "expected_values" => "1.2.3.4",
                 "match_mode" => "not_a_real_mode",
                 "interval_seconds" => "300"
               },
               @scope
             )
  end

  test "monitor_create_attrs rejects a DNS expected_values list over the DB's 20-item cap" do
    too_many = Enum.map_join(1..21, ",", &"10.0.0.#{&1}")

    assert {:error, :invalid_dns_values} =
             MonitorFormAttrs.monitor_create_attrs(
               %{"name" => "Edge", "type" => "dns"},
               %{
                 "hostname" => "edge.example.test",
                 "record_type" => "A",
                 "expected_values" => too_many,
                 "interval_seconds" => "300"
               },
               @scope
             )
  end
end
