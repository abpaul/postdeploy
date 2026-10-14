defmodule Alplus.Observe.SessionEnvelope do
  @moduledoc """
  Parses the `POST /e/sessions` wire envelope (issue #12): additive to, and
  structurally identical in shape to, `Alplus.Observe.ErrorEnvelope`'s
  `{header, items}` envelope -- same header, a different item shape. Kept
  as its own module (not folded into `ErrorEnvelope`) because the item
  validation rules are unrelated: no exception/message/stacktrace fields at
  all, just a session outcome.
  """

  @max_items 100
  @max_id_bytes 64
  @max_environment_bytes 64
  @max_release_bytes 256
  @statuses ~w(healthy errored crashed)

  @spec parse(binary()) ::
          {:ok,
           %{
             header_key: String.t() | nil,
             sdk_name: String.t(),
             sdk_version: String.t(),
             items: [map()]
           }, non_neg_integer()}
          | :error
  def parse(raw) when is_binary(raw) do
    with {:ok, envelope} <- Jason.decode(raw),
         true <- valid_envelope?(envelope),
         {:ok, header} <- parse_header(envelope["header"]) do
      {items, dropped} = envelope["items"] |> Enum.map(&parse_item/1) |> collect_items()
      {:ok, Map.put(header, :items, items), dropped}
    else
      _ -> :error
    end
  end

  defp valid_envelope?(%{"header" => header, "items" => items} = envelope) do
    exact_keys?(envelope, ~w(header items)) and is_map(header) and is_list(items) and
      length(items) in 1..@max_items
  end

  defp valid_envelope?(_), do: false

  defp parse_header(%{"sdk" => sdk} = header) when is_map(sdk) do
    with true <- exact_keys?(header, ~w(key sdk sent_at)),
         true <- exact_keys?(sdk, ~w(name version platform)),
         true <- bounded_string?(sdk["name"], 1, 128),
         true <- bounded_string?(sdk["version"], 1, 64),
         true <- optional_string?(sdk["platform"], 64),
         true <- optional_string?(header["key"], 128),
         true <- optional_string?(header["sent_at"], 64) do
      {:ok,
       %{
         header_key: header["key"],
         sdk_name: sdk["name"],
         sdk_version: sdk["version"]
       }}
    else
      _ -> :error
    end
  end

  defp parse_header(_), do: :error

  defp parse_item(item) when is_map(item) do
    # Released clients may still carry the retired timing keys. They are
    # accepted and discarded; current SDKs and the protocol no longer emit them.
    with true <-
           exact_keys?(
             item,
             ~w(id status release environment started_at duration_ms)
           ),
         true <- bounded_string?(item["id"], 4, @max_id_bytes),
         true <- item["status"] in @statuses,
         true <- optional_string?(item["release"], @max_release_bytes),
         true <- optional_string?(item["environment"], @max_environment_bytes),
         true <- optional_string?(item["started_at"], 64),
         true <- optional_duration?(item["duration_ms"]) do
      {:ok, Map.drop(item, ~w(started_at duration_ms))}
    else
      _ -> :error
    end
  end

  defp parse_item(_), do: :error
  defp optional_duration?(nil), do: true
  defp optional_duration?(value), do: is_integer(value) and value in 0..86_400_000

  defp collect_items(parsed_items) do
    Enum.reduce(parsed_items, {[], 0}, fn
      {:ok, item}, {items, dropped} -> {[item | items], dropped}
      :error, {items, dropped} -> {items, dropped + 1}
    end)
    |> then(fn {items, dropped} -> {Enum.reverse(items), dropped} end)
  end

  defp exact_keys?(map, allowed) do
    map
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.subset?(MapSet.new(allowed))
  end

  defp bounded_string?(value, min, max), do: is_binary(value) and byte_size(value) in min..max
  defp optional_string?(nil, _max), do: true
  defp optional_string?(value, max), do: bounded_string?(value, 0, max)
end
