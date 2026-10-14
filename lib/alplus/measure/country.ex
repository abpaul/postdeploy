defmodule Alplus.Measure.Country do
  @moduledoc """
  Derives the `country` dimension from Cloudflare's `cf-ipcountry` request
  header (issue #9, ARCHITECTURE.md §8). The IP itself is never read here —
  it is used only, elsewhere, to compute the daily-salted visitor hash, and
  is discarded straight after.
  """

  @doc """
  Normalizes a `cf-ipcountry` header value to its two-letter code, or
  `nil` when absent/unknown — Cloudflare sends `"XX"` for an unresolvable
  IP and `"T1"` for Tor exit nodes, neither of which is a real country, so
  both are treated as "no data" rather than fabricated as a country.
  """
  @spec normalize(String.t() | nil) :: String.t() | nil
  def normalize(value) when is_binary(value) do
    code = value |> String.trim() |> String.upcase()

    if Regex.match?(~r/^[A-Z]{2}$/, code) and code not in ["XX", "T1"] do
      code
    else
      nil
    end
  end

  def normalize(_value), do: nil
end
