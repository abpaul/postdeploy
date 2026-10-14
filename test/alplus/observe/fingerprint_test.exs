defmodule Alplus.Observe.FingerprintTest do
  use ExUnit.Case, async: true

  alias Alplus.Observe.Fingerprint

  test "matches the old-worker golden fingerprint cases" do
    fixtures =
      "test/fixtures/observe/fingerprint_golden.json"
      |> File.read!()
      |> Jason.decode!()

    Enum.each(fixtures, fn fixture ->
      subject = atomize_subject(fixture["subject"])
      decision = Fingerprint.build_input(subject)
      result = Fingerprint.compute(subject)

      assert decision.path == String.to_existing_atom(fixture["path"]), fixture["name"]
      assert decision.input == fixture["input"], fixture["name"]
      assert result.fingerprint == fixture["fingerprint"], fixture["name"]
    end)
  end

  test "uses only the top eight in-app frames and ignores source positions" do
    frames =
      Enum.map(0..11, fn index ->
        %{file: "/src/f#{index}.ts", function: "fn#{index}", lineno: index, colno: index}
      end)

    assert Fingerprint.frame_signature(frames) ==
             Enum.map_join(0..7, "\n", fn index -> "fn#{index}@/src/f#{index}.ts" end)
  end

  test "uses a custom in_app annotation over path heuristics in both directions" do
    assert Fingerprint.in_app_frame?(%{file: "/node_modules/react/index.js", in_app: true})
    refute Fingerprint.in_app_frame?(%{file: "/src/checkout.ts", in_app: false})
  end

  test "matches the old worker's path and message normalization cases" do
    assert Fingerprint.normalize_frame_path("https://app.example.com/assets/main.js") ==
             "/assets/main.js"

    assert Fingerprint.normalize_frame_path("https://app.example.com") == "/"

    assert Fingerprint.normalize_frame_path("https://cdn.example.com/main.js?v=7f3a9c#sourceURL") ==
             "/main.js"

    assert Fingerprint.normalize_message("user 018f2b3c4d5e7f8090123456789abcde not found") ==
             "user <uuid> not found"

    assert Fingerprint.normalize_message("retry 3 after -1.5s") == "retry <num> after <num>s"

    assert Fingerprint.normalize_message("lock held since 2026-07-30T14:32:06.902Z") ==
             "lock held since <ts>"
  end

  test "uses anonymous for an empty function name" do
    assert Fingerprint.frame_signature([%{file: "/src/a.ts", function: ""}]) ==
             "<anonymous>@/src/a.ts"
  end

  test "isolates the same error across project and environment" do
    subject = %{
      project_id: "proj_a",
      environment: "production",
      level: "error",
      exception_type: "TypeError",
      frames: [%{file: "/src/checkout.ts", function: "process_order"}]
    }

    production = Fingerprint.compute(subject)
    staging = Fingerprint.compute(%{subject | environment: "staging"})
    other_project = Fingerprint.compute(%{subject | project_id: "proj_b"})

    refute production.fingerprint == staging.fingerprint
    refute production.fingerprint == other_project.fingerprint
  end

  test "derives the issue title and culprit without inventing vendor data" do
    assert Fingerprint.title(%{exception_type: "TypeError", exception_value: "boom"}) ==
             "TypeError: boom"

    assert Fingerprint.title(%{message: "  cache miss "}) == "cache miss"
    assert Fingerprint.title(%{}) == "Unknown error"

    assert Fingerprint.culprit([
             %{file: "/node_modules/react/index.js", function: "call"},
             %{file: "https://app.example.com/assets/checkout.js", function: "process_order"}
           ]) == "/assets/checkout.js:process_order"

    assert Fingerprint.culprit([%{file: "/node_modules/react/index.js", function: "call"}]) == nil
  end

  defp atomize_subject(subject) do
    subject
    |> Enum.map(fn {key, value} -> {String.to_existing_atom(key), atomize_value(key, value)} end)
    |> Map.new()
  end

  defp atomize_value("frames", frames), do: Enum.map(frames, &atomize_frame/1)
  defp atomize_value(_, value), do: value

  defp atomize_frame(frame) do
    frame
    |> Enum.map(fn {key, value} -> {String.to_existing_atom(key), value} end)
    |> Map.new()
  end
end
