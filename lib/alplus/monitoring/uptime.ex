defmodule Alplus.Monitoring.Uptime do
  @moduledoc """
  Computes monitor uptime from outage intervals, never from check row counts.

  Callers provide the requested window, resolved and open incidents, and the
  monitor's paused intervals. Paused time is removed from both the denominator
  and outage time, as required by ARCHITECTURE.md §8.
  """

  @type interval :: %{
          required(:started_at) => DateTime.t(),
          optional(:resolved_at) => DateTime.t() | nil
        }

  @type result :: %{
          uptime: float() | nil,
          monitored_microseconds: non_neg_integer(),
          downtime_microseconds: non_neg_integer()
        }

  @doc """
  Returns time-weighted uptime for a window.

  `incidents` and `paused_intervals` may overlap. The function merges each
  collection before calculating, so overlapping rows never count twice.
  """
  @spec calculate(DateTime.t(), DateTime.t(), [interval()], [interval()]) :: result()
  def calculate(%DateTime{} = window_start, %DateTime{} = window_end, incidents, paused_intervals)
      when is_list(incidents) and is_list(paused_intervals) do
    validate_window!(window_start, window_end)

    window = to_interval(window_start, window_end)
    paused = paused_intervals |> intervals(window, window_end) |> merge_intervals()
    outages = incidents |> intervals(window, window_end) |> merge_intervals()

    monitored_microseconds = interval_duration(window) - total_duration(paused)
    downtime_microseconds = outages |> subtract(paused) |> total_duration()

    uptime =
      case monitored_microseconds do
        0 -> nil
        duration -> (duration - downtime_microseconds) / duration
      end

    %{
      uptime: uptime,
      monitored_microseconds: monitored_microseconds,
      downtime_microseconds: downtime_microseconds
    }
  end

  defp validate_window!(window_start, window_end) do
    if DateTime.compare(window_start, window_end) != :lt do
      raise ArgumentError, "uptime window end must be after its start"
    end
  end

  defp intervals(rows, window, default_end) do
    rows
    |> Enum.map(fn row ->
      start_at = Map.fetch!(row, :started_at)
      end_at = Map.get(row, :resolved_at) || default_end
      clip(to_interval(start_at, end_at), window)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp to_interval(%DateTime{} = start_at, %DateTime{} = end_at) do
    {DateTime.to_unix(start_at, :microsecond), DateTime.to_unix(end_at, :microsecond)}
  end

  defp clip({start_at, end_at}, {window_start, window_end}) do
    start_at = max(start_at, window_start)
    end_at = min(end_at, window_end)

    if start_at < end_at, do: {start_at, end_at}
  end

  defp merge_intervals(intervals) do
    intervals
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce([], fn {start_at, end_at}, merged ->
      case merged do
        [{previous_start, previous_end} | rest] when start_at <= previous_end ->
          [{previous_start, max(previous_end, end_at)} | rest]

        _ ->
          [{start_at, end_at} | merged]
      end
    end)
    |> Enum.reverse()
  end

  defp subtract(outages, pauses) do
    Enum.flat_map(outages, fn outage -> subtract_interval(outage, pauses) end)
  end

  defp subtract_interval({start_at, end_at}, pauses) do
    {pieces, cursor} =
      Enum.reduce(pauses, {[], start_at}, fn {pause_start, pause_end}, {pieces, cursor} ->
        cond do
          pause_end <= cursor ->
            {pieces, cursor}

          pause_start >= end_at ->
            {pieces, cursor}

          true ->
            next_piece_end = min(pause_start, end_at)

            pieces =
              if cursor < next_piece_end, do: [{cursor, next_piece_end} | pieces], else: pieces

            {pieces, max(cursor, min(pause_end, end_at))}
        end
      end)

    pieces = if cursor < end_at, do: [{cursor, end_at} | pieces], else: pieces
    Enum.reverse(pieces)
  end

  defp interval_duration({start_at, end_at}), do: end_at - start_at
  defp total_duration(intervals), do: Enum.sum(Enum.map(intervals, &interval_duration/1))
end
