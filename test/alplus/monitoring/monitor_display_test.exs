defmodule Alplus.Monitoring.MonitorDisplayTest do
  use ExUnit.Case, async: true

  alias Alplus.Monitoring.MonitorDisplay

  test "sanitizes URL userinfo and sensitive query values while preserving host and path" do
    value =
      MonitorDisplay.sanitize_url(
        "https://user:pass@example.test/health?check=1&Authorization=Bearer+secret&password=one&PASS_WD=two&client-credential=three"
      )

    assert value =~ "https://example.test/health"
    assert value =~ "check=1"
    refute value =~ "user:pass"
    refute value =~ "Bearer+secret"
    refute value =~ "one"
    refute value =~ "two"
    refute value =~ "three"
  end

  test "redacts sensitive headers case-insensitively" do
    value =
      MonitorDisplay.format_headers(%{
        "Authorization" => "Bearer secret",
        "cookie" => "session=abc",
        "X-API-Key" => "key",
        "X-Password" => "password-value",
        "X-PASS_WD" => "passwd-value",
        "X-Credential" => "credential-value",
        "X-Auth-User" => "auth-value",
        "X-Request-ID" => "request-1"
      })

    assert value =~ "Authorization: [REDACTED]"
    assert value =~ "cookie: [REDACTED]"
    assert value =~ "X-API-Key: [REDACTED]"
    assert value =~ "X-Password: [REDACTED]"
    assert value =~ "X-PASS_WD: [REDACTED]"
    assert value =~ "X-Credential: [REDACTED]"
    assert value =~ "X-Auth-User: [REDACTED]"
    assert value =~ "X-Request-ID: request-1"
    refute value =~ "Bearer secret"
    refute value =~ "session=abc"
    refute value =~ "password-value"
    refute value =~ "passwd-value"
    refute value =~ "credential-value"
    refute value =~ "auth-value"
  end
end
