defmodule Mix.Tasks.Alplus.Loadtest do
  @moduledoc """
  Runs a local load check through the real Phoenix HTTP listener.

  The task starts the application runtime. `Alplus.LoadTest.Measurement` owns
  the load measurement and accepts the request adapter used for heartbeat
  traffic.

  ## Usage

      mix alplus.loadtest
      mix alplus.loadtest --monitors 1000 --heartbeats 50 \\
        --ingest-requests 10000 --ingest-concurrency 100 --observe-seconds 90
  """
  use Mix.Task

  @shortdoc "Local monitor scheduler and heartbeat load check"

  @impl true
  def run(args) do
    opts = parse_args(args)

    Alplus.LoadTest.Runtime.run(fn base_url ->
      Alplus.LoadTest.Measurement.run(opts,
        adapter: Alplus.LoadTest.Adapter.HTTP,
        base_url: base_url
      )
    end)
  end

  defp parse_args(args) do
    {parsed, _rest} =
      OptionParser.parse!(args,
        strict: [
          monitors: :integer,
          heartbeats: :integer,
          ingest_requests: :integer,
          ingest_concurrency: :integer,
          observe_seconds: :integer
        ]
      )

    %{
      monitors: Keyword.get(parsed, :monitors, 1000),
      heartbeats: Keyword.get(parsed, :heartbeats, 50),
      ingest_requests: Keyword.get(parsed, :ingest_requests, 10_000),
      ingest_concurrency: Keyword.get(parsed, :ingest_concurrency, 100),
      observe_seconds: Keyword.get(parsed, :observe_seconds, 90)
    }
  end
end
