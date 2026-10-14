defmodule Alplus.Observe.ErrorEnvelope do
  @moduledoc false
  @event_id_regex ~r/\Aerr_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  # The id form a Sentry SDK generates (`Alplus.Observe.SentryEnvelope`).
  @sentry_event_id_regex ~r/\A[0-9a-f]{32}\z/

  @max_items 100
  @max_timestamp_bytes 64
  @max_environment_bytes 64
  @max_release_bytes 256
  @max_message_bytes 4_096
  # Source-context bounds per frame: the Ruby SDK caps each line at 500
  # chars (`Stack::MAX_SOURCE_LINE_CHARS`); 1_024 bytes leaves headroom for
  # multi-byte characters. 20 lines covers any sane `context_lines` setting.
  @max_source_line_bytes 1_024
  @max_context_lines 20
  # An exception may carry a bounded chain of `cause` exceptions
  # (Ruby `Exception#cause`, JS `Error#cause`). Depth counts the top-level
  # exception as 1.
  @max_cause_depth 5

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
    with true <-
           exact_keys?(
             item,
             ~w(id type timestamp level release environment message exception fingerprint breadcrumbs contexts tags user mechanism)
           ),
         true <- valid_event_id?(item["id"]),
         true <- item["type"] in ["exception", "message"],
         true <- bounded_string?(item["timestamp"], 1, @max_timestamp_bytes),
         true <- item["level"] in ["fatal", "error", "warning", "info"],
         true <- optional_string?(item["release"], @max_release_bytes),
         true <- optional_string?(item["environment"], @max_environment_bytes),
         true <- optional_string?(item["mechanism"], 64),
         true <- valid_item_type?(item),
         true <- valid_exception?(item["exception"]),
         true <- valid_fingerprint?(item["fingerprint"]),
         true <- valid_breadcrumbs?(item["breadcrumbs"]),
         true <- valid_contexts?(item["contexts"]),
         true <- valid_tags?(item["tags"]),
         true <- valid_user?(item["user"]) do
      {:ok, item}
    else
      _ -> :error
    end
  end

  defp parse_item(_), do: :error

  defp valid_event_id?(id) when is_binary(id),
    do: Regex.match?(@event_id_regex, id) or Regex.match?(@sentry_event_id_regex, id)

  defp valid_event_id?(_id), do: false

  defp valid_item_type?(%{"type" => "exception", "exception" => exception}), do: is_map(exception)

  defp valid_item_type?(%{"type" => "message", "message" => message}),
    do: bounded_string?(message, 1, @max_message_bytes)

  defp valid_item_type?(_), do: false

  defp valid_exception?(exception), do: valid_exception?(exception, @max_cause_depth)

  defp valid_exception?(nil, _depth), do: true

  defp valid_exception?(%{"type" => type} = exception, depth) when depth > 0 do
    exact_keys?(exception, ~w(type value stacktrace cause)) and bounded_string?(type, 1, 256) and
      optional_string?(exception["value"], @max_message_bytes) and
      valid_stacktrace?(exception["stacktrace"]) and
      valid_cause?(exception["cause"], depth - 1)
  end

  defp valid_exception?(_, _depth), do: false

  defp valid_cause?(nil, _depth), do: true
  defp valid_cause?(_cause, 0), do: false
  defp valid_cause?(cause, depth) when is_map(cause), do: valid_exception?(cause, depth)
  defp valid_cause?(_, _depth), do: false

  defp valid_stacktrace?(nil), do: true

  defp valid_stacktrace?(%{"frames" => frames} = stacktrace) when is_list(frames) do
    exact_keys?(stacktrace, ["frames"]) and length(frames) <= 200 and
      Enum.all?(frames, &valid_frame?/1)
  end

  defp valid_stacktrace?(_), do: false

  # `pre_context`/`context_line`/`post_context` are the frame's surrounding
  # source lines (Ruby SDK `Stack.source_context/3`). Before 2026-08-17 these
  # keys were absent from the allowlist, so `exact_keys?` rejected the whole
  # item — every default-configured Ruby capture with an in-app frame was
  # silently dropped as malformed.
  defp valid_frame?(frame) when is_map(frame) do
    exact_keys?(
      frame,
      ~w(file function lineno colno in_app pre_context context_line post_context)
    ) and
      optional_string?(frame["file"], 1_024) and
      optional_string?(frame["function"], 512) and optional_integer?(frame["lineno"]) and
      optional_integer?(frame["colno"]) and optional_boolean?(frame["in_app"]) and
      optional_string?(frame["context_line"], @max_source_line_bytes) and
      valid_context_lines?(frame["pre_context"]) and
      valid_context_lines?(frame["post_context"])
  end

  defp valid_frame?(_), do: false

  defp valid_context_lines?(nil), do: true

  defp valid_context_lines?(lines) when is_list(lines) do
    length(lines) <= @max_context_lines and
      Enum.all?(lines, &bounded_string?(&1, 0, @max_source_line_bytes))
  end

  defp valid_context_lines?(_), do: false

  defp valid_fingerprint?(nil), do: true

  defp valid_fingerprint?(fingerprint) when is_list(fingerprint) do
    length(fingerprint) in 1..16 and Enum.all?(fingerprint, &bounded_string?(&1, 0, 256))
  end

  defp valid_fingerprint?(_), do: false

  defp valid_breadcrumbs?(nil), do: true

  defp valid_breadcrumbs?(breadcrumbs) when is_list(breadcrumbs),
    do: Enum.all?(breadcrumbs, &valid_breadcrumb?/1)

  defp valid_breadcrumbs?(_), do: false

  defp valid_breadcrumb?(breadcrumb) when is_map(breadcrumb) do
    exact_keys?(breadcrumb, ~w(category message level ts data)) and
      optional_string?(breadcrumb["category"], 128) and
      optional_string?(breadcrumb["message"], 2_048) and optional_string?(breadcrumb["level"], 32) and
      optional_string?(breadcrumb["ts"], 64)
  end

  defp valid_breadcrumb?(_), do: false

  defp valid_contexts?(nil), do: true

  defp valid_contexts?(contexts) when is_map(contexts),
    do: Enum.all?(contexts, fn {key, _value} -> is_binary(key) end)

  defp valid_contexts?(_), do: false

  defp valid_tags?(nil), do: true

  defp valid_tags?(tags) when is_map(tags) do
    Enum.all?(tags, fn {key, value} -> is_binary(key) and is_binary(value) end)
  end

  defp valid_tags?(_), do: false

  defp valid_user?(nil), do: true

  defp valid_user?(user) when is_map(user) do
    exact_keys?(user, ~w(id email)) and optional_string?(user["id"], 4_096) and
      optional_string?(user["email"], 4_096)
  end

  defp valid_user?(_), do: false

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
  defp optional_integer?(nil), do: true
  defp optional_integer?(value), do: is_integer(value)
  defp optional_boolean?(nil), do: true
  defp optional_boolean?(value), do: is_boolean(value)
end
