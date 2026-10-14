defmodule Alplus.Observe.ErrorEnvelopeInvalidTest do
  use ExUnit.Case, async: true

  alias Alplus.Observe.ErrorEnvelope

  test "rejects malformed envelopes, headers, and items" do
    assert :error = ErrorEnvelope.parse("not-json")
    assert :error = ErrorEnvelope.parse("{}")
    assert :error = ErrorEnvelope.parse(~s({"header":{},"items":[]}))

    assert :error =
             ErrorEnvelope.parse(
               Jason.encode!(%{
                 "header" => %{"key" => "k", "sdk" => "bad", "sent_at" => "now"},
                 "items" => [%{"type" => "message"}]
               })
             )

    assert {:ok, %{items: []}, 3} =
             ErrorEnvelope.parse(
               Jason.encode!(%{
                 "header" => %{
                   "key" => "k",
                   "sdk" => %{"name" => "n", "version" => "1", "platform" => "elixir"},
                   "sent_at" => "2026-01-01T00:00:00Z"
                 },
                 "items" => [
                   %{"type" => "exception", "exception" => "nope"},
                   %{"type" => "message", "message" => 1},
                   %{"type" => "nope"}
                 ]
               })
             )
  end

  test "accepts only err-prefixed RFC UUIDv7 item ids" do
    for id <- [
          "evt_00000000-0000-7000-8000-000000000000",
          "err_00000000-0000-4000-8000-000000000000",
          "err_00000000-0000-7000-7000-000000000000",
          "err_00000000-0000-7000-c000-000000000000",
          "err_00000000000070008000000000000000",
          "opaque-id"
        ] do
      assert {:ok, %{items: []}, 1} = ErrorEnvelope.parse(envelope(id))
    end

    for variant <- ~w(8 9 a b) do
      id = "err_00000000-0000-7000-#{variant}000-000000000000"
      assert {:ok, %{items: [%{"id" => ^id}]}, 0} = ErrorEnvelope.parse(envelope(id))
    end
  end

  defp envelope(id) do
    Jason.encode!(%{
      "header" => %{
        "key" => "k",
        "sdk" => %{"name" => "n", "version" => "1", "platform" => "elixir"},
        "sent_at" => "2026-01-01T00:00:00Z"
      },
      "items" => [
        %{
          "id" => id,
          "type" => "message",
          "timestamp" => "2026-01-01T00:00:00Z",
          "level" => "error",
          "message" => "boom"
        }
      ]
    })
  end
end
