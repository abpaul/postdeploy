defmodule Alplus.Growth.HealthCheck do
  @moduledoc """
  Records the five website-health-check funnel stages against a journey id.

  Acquisition events never include a target URL, DNS answer, or result body.
  """

  @stages ~w(health_check_started health_check_result_produced signup configured activated)

  @spec new_journey_id() :: String.t()
  def new_journey_id do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  @spec record(String.t(), String.t(), String.t() | nil) :: :ok
  def record(journey_id, stage, user_id \\ nil)

  def record(journey_id, stage, user_id)
      when is_binary(journey_id) and stage in @stages do
    attrs = %{journey_id: journey_id, stage: stage, user_id: user_id}

    case Alplus.Growth.record_journey_event(attrs, authorize?: false) do
      {:ok, _row} -> :ok
      _ -> :ok
    end
  end

  def record(_journey_id, _stage, _user_id), do: :ok

  @spec counts(DateTime.t()) :: %{String.t() => non_neg_integer()}
  def counts(%DateTime{} = since) do
    %{rows: event_rows} =
      Alplus.Repo.query!(
        """
        SELECT stage, count(*)
        FROM growth_journey_events
        WHERE inserted_at >= $1
        GROUP BY stage
        """,
        [since]
      )

    %{rows: aggregate_rows} =
      Alplus.Repo.query!(
        """
        SELECT stage, coalesce(sum(count), 0)
        FROM growth_health_check_daily_counts
        WHERE day >= $1
        GROUP BY stage
        """,
        [DateTime.to_date(since)]
      )

    empty = Map.new(@stages, &{&1, 0})

    empty
    |> add_rows(event_rows)
    |> add_rows(aggregate_rows)
  end

  defp add_rows(acc, rows) do
    Enum.reduce(rows, acc, fn [stage, count], acc ->
      Map.update(acc, stage, count, &(&1 + count))
    end)
  end
end
