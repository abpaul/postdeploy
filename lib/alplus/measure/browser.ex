defmodule Alplus.Measure.Browser do
  @moduledoc """
  Parses the `User-Agent` request header into a fixed, closed-set label
  (issue #9). The raw string is never stored — only the label reaches
  `analytics_dimensions`; the caller discards the header right after.

  Order matters: several browsers' user-agent strings include `"Chrome"`
  and/or `"Safari"` as compatibility tokens (Edge, Opera, Samsung Internet
  are all Chromium-based), so the more specific engine markers are checked
  first.
  """

  @labels ~w(Edge Opera Samsung Firefox Chrome Safari)

  @doc "Returns the closed-set browser label for `user_agent`, defaulting to \"Other\"."
  @spec label(String.t() | nil) :: String.t()
  def label(user_agent) when is_binary(user_agent) and user_agent != "" do
    Enum.find_value(@labels, "Other", fn label ->
      if matches?(label, user_agent), do: label
    end)
  end

  def label(_user_agent), do: "Other"

  @doc "The closed set of labels this module can return."
  @spec labels :: [String.t()]
  def labels, do: @labels ++ ["Other"]

  defp matches?("Edge", ua), do: ua =~ ~r/Edg(e|A|iOS)?\//
  defp matches?("Opera", ua), do: ua =~ ~r/OPR\/|Opera/
  defp matches?("Samsung", ua), do: ua =~ "SamsungBrowser/"
  defp matches?("Firefox", ua), do: ua =~ ~r/Firefox\/|FxiOS\//
  defp matches?("Chrome", ua), do: ua =~ ~r/Chrome\/|CriOS\//
  defp matches?("Safari", ua), do: ua =~ ~r/Safari\//
end
