defmodule Alplus.Observe.GoldenEnvelopeTest do
  @moduledoc """
  The server anchor for the shared SDK contract (issue #18):
  `sdks/contract/*.json` are the golden wire items every SDK (Elixir, Ruby,
  JS) must reproduce. This test feeds each golden, wrapped in a minimal
  envelope, through the REAL server parsers
  (`Alplus.Observe.ErrorEnvelope.parse/1`,
  `Alplus.Observe.SessionEnvelope.parse/1`) and asserts it parses cleanly
  (zero dropped items) -- making "matches golden" mean "the server accepts
  it." A server schema change that stops accepting one of these fixtures
  fails HERE first, before it can silently break an SDK.

  No Postgres/Ash needed: the envelope parsers are pure functions over the
  raw JSON body.
  """

  use ExUnit.Case, async: true

  alias Alplus.Measure.Hit
  alias Alplus.Observe.{ErrorEnvelope, SessionEnvelope}

  # The product owns the contract, so the anchor reads the local directory
  # directly (unlike each SDK, which consumes it as an external, pinned input --
  # issue #26). `manifest.json` assigns the fixture set a semantic version.
  @contract_dir Path.expand("../../../sdks/contract", __DIR__)
  @contract_version "2.0.0"
  @external_resource Path.join(@contract_dir, "manifest.json")
  @external_resource Path.join(@contract_dir, "exception_item.json")
  @external_resource Path.join(@contract_dir, "message_item.json")
  @external_resource Path.join(@contract_dir, "session_item.json")
  @external_resource Path.join(@contract_dir, "measure_event.json")

  defp golden(name) do
    @contract_dir |> Path.join(name) |> File.read!() |> Jason.decode!()
  end

  defp manifest do
    @contract_dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
  end

  test "the contract manifest pins the current version and the fixtures' checksums" do
    manifest = manifest()
    assert manifest["version"] == @contract_version

    for {name, expected} <- manifest["items"] do
      digest =
        @contract_dir |> Path.join(name) |> File.read!() |> then(&:crypto.hash(:sha256, &1))

      actual = "sha256:" <> Base.encode16(digest, case: :lower)

      assert actual == expected,
             "manifest checksum for #{name} is stale -- bump the contract version and update manifest.json"
    end
  end

  defp error_envelope(item) do
    Jason.encode!(%{
      "header" => %{
        "key" => "alp_p_contract_test",
        "sdk" => %{"name" => "contract-test", "version" => "0.0.0", "platform" => "test"},
        "sent_at" => "2024-01-01T00:00:00.000Z"
      },
      "items" => [item]
    })
  end

  test "the golden exception item parses through the real ErrorEnvelope parser" do
    item = golden("exception_item.json")

    assert {:ok, envelope, 0} = ErrorEnvelope.parse(error_envelope(item))
    assert [parsed_item] = envelope.items
    assert parsed_item["type"] == "exception"
    assert parsed_item["exception"]["type"] == "ContractTestError"
    assert length(get_in(parsed_item, ["exception", "stacktrace", "frames"])) == 2
  end

  test "the golden message item parses through the real ErrorEnvelope parser" do
    item = golden("message_item.json")

    assert {:ok, envelope, 0} = ErrorEnvelope.parse(error_envelope(item))
    assert [parsed_item] = envelope.items
    assert parsed_item["type"] == "message"
    assert parsed_item["message"] == "canonical contract test message"
  end

  test "the golden session item parses through the real SessionEnvelope parser" do
    item = golden("session_item.json")

    assert {:ok, envelope, 0} = SessionEnvelope.parse(error_envelope(item))
    assert [parsed_item] = envelope.items
    assert parsed_item["status"] == "crashed"
    refute Map.has_key?(parsed_item, "started_at")
    refute Map.has_key?(parsed_item, "duration_ms")
  end

  test "retired session timing fields remain ingest-compatible but are discarded" do
    item =
      golden("session_item.json")
      |> Map.merge(%{"started_at" => "2024-01-01T00:00:00Z", "duration_ms" => 12_345})

    assert {:ok, %{items: [parsed_item]}, 0} = SessionEnvelope.parse(error_envelope(item))
    refute Map.has_key?(parsed_item, "started_at")
    refute Map.has_key?(parsed_item, "duration_ms")
  end

  test "the exception and message goldens are dropped as malformed by the session parser (item shapes are disjoint)" do
    assert {:ok, %{items: []}, 1} =
             SessionEnvelope.parse(error_envelope(golden("exception_item.json")))

    assert {:ok, %{items: []}, 1} =
             SessionEnvelope.parse(error_envelope(golden("message_item.json")))
  end

  test "the session golden is dropped as malformed by the error parser (item shapes are disjoint)" do
    assert {:ok, %{items: []}, 1} =
             ErrorEnvelope.parse(error_envelope(golden("session_item.json")))
  end

  test "the golden Measure event parses and discards properties" do
    assert {:ok, hit} = Hit.normalize(golden("measure_event.json"))
    assert hit == %{type: "event", hostname: "app.example.test", name: "signup"}
    refute Map.has_key?(hit, :props)
  end
end
