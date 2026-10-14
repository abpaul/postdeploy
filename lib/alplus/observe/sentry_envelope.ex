defmodule Alplus.Observe.SentryEnvelope do
  @moduledoc """
  Reads the envelope a Sentry SDK posts and maps each `event` item to the
  Observe error item that `Alplus.Observe.Ingest.capture_item/2` accepts.

  Every other item type (session, transaction, client report, check-in) is
  skipped. The mapper clips each field to the bound `ErrorEnvelope` enforces,
  because that parser drops a whole item on one oversized field.
  """

  @max_events 100
  # An envelope from an SDK holds a handful of items. The bound stops a body
  # of many tiny items from costing a JSON decode each.
  @max_lines 400
  # Year 5138 in Unix seconds; larger floats overflow the microsecond conversion.
  @max_unix_seconds 100_000_000_000
  @max_inflated_bytes 4 * 1_048_576
  @max_frames 200
  @max_cause_depth 5
  @max_context_lines 20
  @max_source_line_bytes 1_024
  @max_message_bytes 4_096
  @max_breadcrumbs 100
  @event_id_regex ~r/\A[0-9a-f]{32}\z/
  @rust_toolchain_paths ["/.cargo/registry/", "/rustc/", "/rustlib/"]

  @spec inflate(binary(), String.t() | nil) ::
          {:ok, binary()} | :too_large | :unsupported_encoding | :error
  def inflate(raw, encoding) when encoding in [nil, "", "identity"], do: {:ok, raw}
  def inflate(raw, "gzip"), do: inflate_zlib(raw, 31)
  def inflate(raw, "deflate"), do: inflate_zlib(raw, 15)
  def inflate(_raw, _encoding), do: :unsupported_encoding

  defp inflate_zlib(raw, window_bits) do
    stream = :zlib.open()

    try do
      :zlib.inflateInit(stream, window_bits)
      inflate_chunks(stream, :zlib.safeInflate(stream, raw), [], 0)
    rescue
      _error -> :error
    after
      :zlib.close(stream)
    end
  end

  defp inflate_chunks(stream, {status, output}, chunks, size) do
    size = size + IO.iodata_length(output)

    cond do
      size > @max_inflated_bytes -> :too_large
      status == :finished -> finish_inflate(stream, [chunks, output])
      true -> inflate_chunks(stream, :zlib.safeInflate(stream, []), [chunks, output], size)
    end
  end

  # `inflateEnd/1` raises when the input stopped before the end of the
  # stream, so a truncated body is an error and not a short envelope.
  defp finish_inflate(stream, chunks) do
    :zlib.inflateEnd(stream)
    {:ok, IO.iodata_to_binary(chunks)}
  end

  @doc """
  Returns the envelope's event id and its mapped `event` items. `dropped`
  counts `event` items that cannot become an Observe item.
  """
  @spec parse(binary()) ::
          {:ok, %{event_id: String.t() | nil, items: [map()], dropped: non_neg_integer()}}
          | :error
  def parse(raw) when is_binary(raw) do
    {header_line, rest} = split_line(raw)

    with {:ok, header} when is_map(header) <- Jason.decode(header_line),
         {:ok, events} <- read_items(rest, [], 0, @max_lines) do
      {items, dropped} = map_events(events, header)

      {:ok,
       %{
         event_id: event_id(header["event_id"]) || first_event_id(items),
         items: items,
         dropped: dropped
       }}
    else
      _ -> :error
    end
  end

  defp read_items(_rest, _events, count, lines) when count > @max_events or lines == 0,
    do: :error

  defp read_items(rest, events, count, lines) do
    case split_line(rest) do
      {"", ""} ->
        {:ok, Enum.reverse(events)}

      {"", rest} ->
        read_items(rest, events, count, lines - 1)

      {item_header_line, rest} ->
        with {:ok, item_header} when is_map(item_header) <- Jason.decode(item_header_line),
             {:ok, payload, rest} <- read_payload(rest, item_header["length"]) do
          case item_header["type"] do
            "event" -> read_items(rest, [payload | events], count + 1, lines - 1)
            _other -> read_items(rest, events, count, lines - 1)
          end
        else
          _ -> :error
        end
    end
  end

  defp read_payload(rest, nil) do
    {payload, rest} = split_line(rest)
    {:ok, payload, rest}
  end

  defp read_payload(rest, length)
       when is_integer(length) and length >= 0 and length <= byte_size(rest) do
    payload = binary_part(rest, 0, length)

    case binary_part(rest, length, byte_size(rest) - length) do
      "\n" <> rest -> {:ok, payload, rest}
      "" -> {:ok, payload, ""}
      _ -> :error
    end
  end

  defp read_payload(_rest, _length), do: :error

  defp split_line(binary) do
    case :binary.split(binary, "\n") do
      [line, rest] -> {line, rest}
      [line] -> {line, ""}
    end
  end

  defp map_events(events, header) do
    Enum.reduce(events, {[], 0}, fn payload, {items, dropped} ->
      with {:ok, event} when is_map(event) <- Jason.decode(payload),
           {:ok, item} <- to_item(event, header) do
        {[item | items], dropped}
      else
        _ -> {items, dropped + 1}
      end
    end)
    |> then(fn {items, dropped} -> {Enum.reverse(items), dropped} end)
  end

  defp first_event_id([item | _]), do: item["event_id"]
  defp first_event_id([]), do: nil

  defp to_item(event, header) do
    exception = exception(event["exception"])
    message = message(event)
    id = event_id(event["event_id"]) || event_id(header["event_id"])
    sdk = sdk(event["sdk"]) || sdk(header["sdk"]) || %{}

    cond do
      is_nil(id) ->
        :error

      is_nil(exception) and is_nil(message) ->
        :error

      true ->
        {:ok,
         %{
           "event_id" => id,
           "type" => if(exception, do: "exception", else: "message"),
           "timestamp" => timestamp(event["timestamp"]),
           "level" => level(event["level"]),
           "release" => event["release"] |> text() |> clip(256),
           "message" => message,
           "exception" => exception,
           "fingerprint" => fingerprint(event["fingerprint"]),
           "breadcrumbs" => breadcrumbs(event["breadcrumbs"]),
           "contexts" => contexts(event),
           "tags" => tags(event["tags"]),
           "user" => user(event["user"]),
           "mechanism" => mechanism(event["exception"]),
           "sdk_name" => sdk["name"] || "sentry",
           "sdk_version" => sdk["version"] || "unknown"
         }}
    end
  end

  defp event_id(id) when is_binary(id) do
    normalized = id |> String.downcase() |> String.replace("-", "")
    if Regex.match?(@event_id_regex, normalized), do: normalized
  end

  defp event_id(_id), do: nil

  defp sdk(%{} = sdk) do
    %{
      "name" => sdk["name"] |> text() |> present() |> clip(128),
      "version" => sdk["version"] |> text() |> present() |> clip(64)
    }
  end

  defp sdk(_sdk), do: nil

  # Sentry SDKs send ISO 8601 with or without an offset, or Unix seconds.
  defp timestamp(value) when is_binary(value) do
    with {:error, _reason} <- DateTime.from_iso8601(value),
         {:error, _reason} <- DateTime.from_iso8601(value <> "Z") do
      now()
    else
      {:ok, datetime, _offset} -> DateTime.to_iso8601(datetime)
    end
  end

  defp timestamp(value) when is_number(value) and abs(value) < @max_unix_seconds do
    case DateTime.from_unix(trunc(value * 1_000_000), :microsecond) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      {:error, _reason} -> now()
    end
  end

  defp timestamp(_value), do: now()

  defp now, do: DateTime.to_iso8601(DateTime.utc_now())

  defp level(level) when level in ["fatal", "error", "warning", "info"], do: level
  defp level(level) when level in ["debug", "log"], do: "info"
  defp level(_level), do: "error"

  defp message(event) do
    [event["message"], event["logentry"]]
    |> Enum.find_value(fn
      %{} = entry -> present(text(entry["formatted"])) || present(text(entry["message"]))
      value -> present(text(value))
    end)
    |> clip(@max_message_bytes)
  end

  # Sentry lists a chain oldest first: the last value is the exception that
  # reached the SDK, and each earlier value is the cause of the next.
  defp exception(%{"values" => values}), do: exception(values)

  defp exception(values) when is_list(values) do
    values
    |> Enum.filter(&is_map/1)
    |> Enum.take(-@max_cause_depth)
    |> Enum.reduce(nil, fn value, cause ->
      %{
        "type" => value["type"] |> text() |> present() |> clip(256) || "Error",
        "value" => value |> exception_value() |> clip(@max_message_bytes),
        "stacktrace" => stacktrace(value["stacktrace"]),
        "cause" => cause
      }
    end)
  end

  defp exception(_exception), do: nil

  # `sentry-ruby` appends the class to the message: `boom (RuntimeError)`.
  defp exception_value(%{"type" => type, "value" => value})
       when is_binary(type) and is_binary(value),
       do: String.replace_suffix(value, " (" <> type <> ")", "")

  defp exception_value(value), do: text(value["value"])

  defp mechanism(%{"values" => values}), do: mechanism(values)

  defp mechanism(values) when is_list(values) do
    case List.last(values) do
      %{"mechanism" => %{"type" => type}} -> type |> text() |> clip(64)
      _ -> nil
    end
  end

  defp mechanism(_exception), do: nil

  # Sentry orders frames oldest call first. Observe stores the crash site first.
  defp stacktrace(%{"frames" => frames}) when is_list(frames) do
    frames =
      frames
      |> Enum.filter(&is_map/1)
      |> Enum.take(-@max_frames)
      |> Enum.reverse()
      |> Enum.map(&frame/1)

    %{"frames" => frames}
  end

  defp stacktrace(_stacktrace), do: nil

  defp frame(frame) do
    abs_path = text(frame["abs_path"])

    %{
      "file" => frame |> file(abs_path) |> clip(1_024),
      "function" => frame["function"] |> text() |> clip(512),
      "lineno" => integer(frame["lineno"]),
      "colno" => integer(frame["colno"]),
      "in_app" => in_app(frame["in_app"], abs_path),
      "context_line" => source_line(frame["context_line"]),
      "pre_context" => context_lines(frame["pre_context"], -@max_context_lines),
      "post_context" => context_lines(frame["post_context"], @max_context_lines)
    }
    |> compact()
  end

  # `sentry-rust` sends a bare file name (`mod.rs`) and keeps the path in
  # `abs_path`.
  defp file(frame, abs_path) do
    filename = text(frame["filename"])

    cond do
      is_binary(filename) and String.contains?(filename, "/") -> filename
      is_binary(abs_path) -> abs_path
      true -> filename || text(frame["module"])
    end
  end

  # `sentry-rust` marks its own panic handler and parts of the standard
  # library as application code. Those frames would become the culprit and
  # the grouping key of every panic.
  defp in_app(true, abs_path) when is_binary(abs_path),
    do: not String.contains?(abs_path, @rust_toolchain_paths)

  defp in_app(value, _abs_path) when is_boolean(value), do: value
  defp in_app(_value, _abs_path), do: nil

  defp context_lines(lines, take) when is_list(lines) and lines != [] do
    lines
    |> Enum.filter(&is_binary/1)
    |> Enum.take(take)
    |> Enum.map(&source_line/1)
  end

  defp context_lines(_lines, _take), do: nil

  defp source_line(line) when is_binary(line),
    do: line |> String.trim_trailing("\n") |> clip(@max_source_line_bytes)

  defp source_line(_line), do: nil

  # `{{ default }}` asks the server to use its own grouping.
  defp fingerprint(fingerprint) when is_list(fingerprint) do
    parts = fingerprint |> Enum.map(&text/1) |> Enum.reject(&is_nil/1)

    if parts == [] or Enum.any?(parts, &(String.replace(&1, " ", "") == "{{default}}")) do
      nil
    else
      parts |> Enum.take(16) |> Enum.map(&clip(&1, 256))
    end
  end

  defp fingerprint(_fingerprint), do: nil

  defp breadcrumbs(%{"values" => values}), do: breadcrumbs(values)

  defp breadcrumbs(values) when is_list(values) and values != [] do
    values
    |> Enum.filter(&is_map/1)
    |> Enum.take(-@max_breadcrumbs)
    |> Enum.map(fn crumb ->
      %{
        "category" => crumb["category"] |> text() |> clip(128),
        "message" => crumb["message"] |> text() |> clip(2_048),
        "level" => crumb["level"] |> text() |> clip(32),
        "ts" => breadcrumb_timestamp(crumb["timestamp"]),
        "data" => if(is_map(crumb["data"]), do: crumb["data"])
      }
      |> compact()
    end)
  end

  defp breadcrumbs(_breadcrumbs), do: nil

  defp breadcrumb_timestamp(value) when is_binary(value) or is_number(value),
    do: timestamp(value)

  defp breadcrumb_timestamp(_value), do: nil

  defp contexts(event) do
    contexts = if is_map(event["contexts"]), do: event["contexts"], else: %{}

    contexts =
      Enum.reduce(["request", "extra"], contexts, fn key, contexts ->
        case event[key] do
          %{} = value when map_size(value) > 0 -> Map.put(contexts, key, value)
          _ -> contexts
        end
      end)

    if map_size(contexts) > 0, do: contexts
  end

  defp tags(%{} = tags), do: tags |> Enum.to_list() |> tag_map()
  defp tags(tags) when is_list(tags), do: tag_map(tags)
  defp tags(_tags), do: nil

  defp tag_map(pairs) do
    tags =
      for pair <- pairs,
          {key, value} <- [tag_pair(pair)],
          is_binary(key),
          value = text(value),
          into: %{},
          do: {key, value}

    if map_size(tags) > 0, do: tags
  end

  defp tag_pair({key, value}), do: {key, value}
  defp tag_pair([key, value]), do: {key, value}
  defp tag_pair(_pair), do: {nil, nil}

  defp user(%{} = user) do
    case compact(%{
           "id" => user["id"] |> text() |> clip(4_096),
           "email" => user["email"] |> text() |> clip(4_096)
         }) do
      empty when map_size(empty) == 0 -> nil
      user -> user
    end
  end

  defp user(_user), do: nil

  defp text(value) when is_binary(value), do: value
  defp text(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp text(value) when is_boolean(value), do: to_string(value)
  defp text(_value), do: nil

  defp present(""), do: nil
  defp present(value), do: value

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: nil

  defp clip(value, max) when is_binary(value) and byte_size(value) > max,
    do: value |> binary_part(0, max) |> trim_to_valid_utf8()

  defp clip(value, _max), do: value

  defp trim_to_valid_utf8(binary) do
    if String.valid?(binary),
      do: binary,
      else: trim_to_valid_utf8(binary_part(binary, 0, byte_size(binary) - 1))
  end

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
