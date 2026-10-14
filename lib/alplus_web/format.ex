defmodule AlplusWeb.Format do
  @moduledoc """
  Small presentation helpers shared by more than one web surface.

  Every timestamp the console renders is UTC. `format_utc/1` prints minute
  precision for lists and detail pages. `format_utc_seconds/1` prints second
  precision for check-level monitor evidence.

  `window_words/1` and `window_axis/2` name the console's four activity
  windows for copy and chart axes.
  """

  @spec format_utc(DateTime.t()) :: String.t()
  def format_utc(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

  @spec format_utc_seconds(DateTime.t() | nil) :: String.t()
  def format_utc_seconds(nil), do: "Unavailable"

  def format_utc_seconds(datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")

  @doc "The window as a person would say it, e.g. `\"7d\"` -> `\"7 days\"`."
  @spec window_words(String.t()) :: String.t()
  def window_words("24h"), do: "24 hours"
  def window_words("7d"), do: "7 days"
  def window_words("30d"), do: "30 days"
  def window_words("90d"), do: "90 days"
  def window_words(window), do: window

  @doc "Chart axis end labels for a window; `end_label` names the right edge."
  @spec window_axis(String.t(), String.t()) :: %{start: String.t(), end: String.t()}
  def window_axis(window, end_label \\ "now")
  def window_axis("24h", end_label), do: %{start: "-24h", end: end_label}
  def window_axis("7d", end_label), do: %{start: "-7d", end: end_label}
  def window_axis("30d", end_label), do: %{start: "-30d", end: end_label}
  def window_axis("90d", end_label), do: %{start: "-90d", end: end_label}
  def window_axis(_window, end_label), do: %{start: "start", end: end_label}
end
