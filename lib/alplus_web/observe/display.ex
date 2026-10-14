defmodule AlplusWeb.Observe.Display do
  @moduledoc """
  Badge labels and tones for Observe issue levels and issue statuses.

  The Observe index, the Source detail page, and the issue page render the
  same level and status vocabulary, so they read those labels here.
  """

  @spec level_tone(String.t()) :: String.t()
  def level_tone("fatal"), do: "error"
  def level_tone("error"), do: "error"
  def level_tone("warning"), do: "warning"
  def level_tone("info"), do: "info"
  def level_tone(_level), do: "neutral"

  @spec status_label(atom()) :: String.t()
  def status_label(:open), do: "Open"
  def status_label(:resolved), do: "Resolved"
  def status_label(:ignored), do: "Ignored"
  def status_label(status), do: String.capitalize(to_string(status))

  @spec level_option_label(String.t()) :: String.t()
  def level_option_label("all"), do: "All levels"
  def level_option_label(level), do: String.capitalize(level)

  @spec status_option_label(String.t()) :: String.t()
  def status_option_label("all"), do: "All statuses"
  def status_option_label(status), do: String.capitalize(status)
end
