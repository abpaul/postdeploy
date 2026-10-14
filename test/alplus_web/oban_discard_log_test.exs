defmodule AlplusWeb.ObanDiscardLogTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Alplus.Repo

  import ExUnit.CaptureLog

  defmodule AlwaysRaises do
    use Oban.Worker, queue: :mailer, max_attempts: 3

    @impl Oban.Worker
    def perform(_job), do: raise("relay refused")
  end

  # The pruner deletes a discarded row after a week. Without this log line a
  # password reset that failed ten times would leave no trace anywhere.
  test "the final failed attempt logs one discard line with safe job identifiers" do
    reset_token = "reset-token-must-not-reach-logs"

    log =
      capture_log(fn ->
        assert_raise RuntimeError, "relay refused", fn ->
          perform_job(AlwaysRaises, %{"purpose" => "password_reset", "token" => reset_token},
            attempt: 3,
            max_attempts: 3
          )
        end
      end)

    lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "oban job discarded"))
    assert [line] = lines
    assert line =~ "after 3 of 3 attempts"
    assert line =~ "relay refused"
    assert line =~ "queue=mailer"
    assert line =~ "worker=AlplusWeb.ObanDiscardLogTest.AlwaysRaises"
    assert line =~ "arg_keys=purpose,token"
    refute line =~ reset_token
    refute line =~ "password_reset"
  end

  test "a retryable failure does not log a discard" do
    log =
      capture_log(fn ->
        assert_raise RuntimeError, fn ->
          perform_job(AlwaysRaises, %{}, attempt: 1, max_attempts: 3)
        end
      end)

    refute log =~ "oban job discarded"
  end
end
