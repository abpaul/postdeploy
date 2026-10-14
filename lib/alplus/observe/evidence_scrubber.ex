defmodule Alplus.Observe.EvidenceScrubber do
  @moduledoc """
  Redacts sensitive keys out of Observe evidence before it renders or copies.

  Evidence (event context, breadcrumb data, the full stored payload) comes
  from whatever the SDK captured, unreviewed. `scrub/1` walks it recursively
  and replaces any value whose key looks like a credential with
  `"[REDACTED]"`, and bounds map size, list length, string length, and
  nesting depth so one adversarial payload cannot blow up the page.
  """

  @max_depth 6
  @max_items 100
  @max_string_length 2_000

  @doc """
  Returns `value` with sensitive keys redacted and size/depth bounded.

  A key matches when it contains (case-insensitively) `authorization`,
  `cookie`, `password`, `secret`, `token`, `api_key`/`api-key`, or `email`.
  """
  @spec scrub(term()) :: term()
  def scrub(value), do: scrub(value, 0)

  defp scrub(_value, depth) when depth >= @max_depth, do: "[TRUNCATED]"

  defp scrub(value, depth) when is_map(value) do
    value
    |> Enum.take(@max_items)
    |> Map.new(fn {key, item} ->
      key = to_string(key)
      {key, if(sensitive_key?(key), do: "[REDACTED]", else: scrub(item, depth + 1))}
    end)
  end

  defp scrub(value, depth) when is_list(value),
    do: value |> Enum.take(@max_items) |> Enum.map(&scrub(&1, depth + 1))

  defp scrub(value, _depth) when is_binary(value),
    do: String.slice(value, 0, @max_string_length)

  defp scrub(value, _depth), do: value

  defp sensitive_key?(key) do
    Regex.match?(~r/(authorization|cookie|password|secret|token|api[_-]?key|email)/i, key)
  end
end
