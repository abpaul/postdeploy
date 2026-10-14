defmodule AlplusWeb.JSONFormatterTest do
  use ExUnit.Case, async: true

  test "encodes one JSON object with correlation metadata" do
    line =
      AlplusWeb.JSONFormatter.format(
        :warning,
        "request failed",
        {{2026, 8, 30}, {12, 34, 56, 789}},
        request_id: "req-1",
        user_id: "user-1",
        org_id: "org-1",
        job_id: 42,
        kamal_version: "release-1",
        remote_ip: {203, 0, 113, 10}
      )

    [json, "\n"] = line
    payload = Jason.decode!(json)

    assert payload["timestamp"] == "2026-08-30T12:34:56.789000Z"
    assert payload["level"] == "warning"
    assert payload["message"] == "request failed"

    assert payload["metadata"] == %{
             "request_id" => "req-1",
             "user_id" => "user-1",
             "org_id" => "org-1",
             "job_id" => 42,
             "kamal_version" => "release-1"
           }
  end
end
