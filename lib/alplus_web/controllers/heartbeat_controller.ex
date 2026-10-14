defmodule AlplusWeb.HeartbeatController do
  @moduledoc """
  Heartbeat ingest (ARCHITECTURE.md §8).

  Two URL forms select the ping state, and both are part of the shipped
  wire contract:

  * `?state=start|finish|fail`, omitted means finish.
  * `/h/:token/:exit_code`, where `0` is a finish and any other value is a
    fail. `@alplus/sdk`'s `exitCode` option and the documented crontab
    one-liner (`curl ".../h/$TOKEN/$?"`) both send this form, which lets a
    shell report a job's real exit status without branching.

  An unparseable or out-of-range exit code is treated as a failure rather
  than a 404: the job did report in, and the safe reading of a malformed
  status from a job wrapper is "something went wrong", not "ignore this".
  """

  use AlplusWeb, :controller

  @valid_states %{"start" => :start, "finish" => :finish, "fail" => :fail}

  def ping_get(conn, params), do: ping(conn, params)

  def ping(conn, %{"token" => token} = params) do
    result =
      Alplus.Monitoring.Heartbeat.accept(
        token,
        state(params),
        normalize_ping_id(params["ping_id"])
      )

    Alplus.Ingest.OperationalMonitor.outcome(
      :heartbeat,
      nil,
      if(result in [:paused, :accepted], do: 1, else: 0),
      if(result == :unknown, do: 1, else: 0),
      result
    )

    case result do
      :unknown -> send_resp(conn, 404, "")
      :paused -> send_resp(conn, 202, "")
      :accepted -> send_resp(conn, 202, "")
    end
  rescue
    DBConnection.ConnectionError ->
      conn
      |> put_resp_header("retry-after", "1")
      |> send_resp(503, "")
  end

  defp normalize_ping_id(value) when is_binary(value) do
    if byte_size(value) in 1..128 and value =~ ~r/\A[A-Za-z0-9_.-]+\z/,
      do: value,
      else: nil
  end

  defp normalize_ping_id(_value), do: nil

  # The path form wins when present: a caller that put an exit code in the
  # path asked for exit-code semantics.
  defp state(%{"exit_code" => exit_code}) do
    case Integer.parse(exit_code) do
      {0, ""} -> :finish
      _ -> :fail
    end
  end

  defp state(params), do: Map.get(@valid_states, params["state"], :finish)
end
