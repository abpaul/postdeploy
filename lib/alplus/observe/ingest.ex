defmodule Alplus.Observe.Ingest do
  @moduledoc "Shared Observe error-envelope validation and write path."

  alias Alplus.Observe.{AlertRouter, ErrorEnvelope, EventWriter, PayloadStore}
  alias Alplus.Security.BearerToken

  @spec parse(binary()) :: {:ok, map(), non_neg_integer()} | :malformed
  def parse(raw) when is_binary(raw) do
    case ErrorEnvelope.parse(raw) do
      {:ok, envelope, dropped} -> {:ok, envelope, dropped}
      :error -> :malformed
    end
  end

  def parse(_raw), do: :malformed

  @spec header_matches?(String.t() | nil, String.t()) :: :ok | :header_key_mismatch
  def header_matches?(nil, _bearer), do: :ok

  def header_matches?(header_key, bearer) when is_binary(header_key) and is_binary(bearer) do
    if BearerToken.matches?(BearerToken.hash(header_key), BearerToken.hash(bearer)),
      do: :ok,
      else: :header_key_mismatch
  end

  def header_matches?(_header_key, _bearer), do: :header_key_mismatch

  @spec write_items(map(), map(), non_neg_integer()) ::
          {:ok,
           %{
             event_ids: [String.t()],
             dropped: non_neg_integer(),
             dropped_reason: String.t() | nil
           }}
          | {:write_failed, term()}
  def write_items(envelope, source, malformed) when is_map(envelope) and is_map(source) do
    Enum.reduce_while(
      envelope.items,
      {:ok, %{event_ids: [], malformed: malformed, duplicates: 0, quota_dropped: 0}},
      fn item, {:ok, result} ->
        case to_event(item, envelope, source) do
          {:ok, event} ->
            case EventWriter.record(event) do
              {:ok, %{event_id: event_id}} ->
                {:cont, {:ok, %{result | event_ids: [event_id | result.event_ids]}}}

              {:ok, :quota_dropped} ->
                {:cont, {:ok, %{result | quota_dropped: result.quota_dropped + 1}}}

              {:ok, :duplicate} ->
                {:cont, {:ok, %{result | duplicates: result.duplicates + 1}}}

              {:error, reason} ->
                {:halt, {:write_failed, reason}}
            end

          {:error, reason} ->
            {:halt, {:write_failed, reason}}

          :error ->
            {:cont, {:ok, %{result | malformed: result.malformed + 1}}}
        end
      end
    )
    |> summarize_writes(source)
  end

  @doc "Capture one item through the same parser and writer as HTTP ingest."
  @spec capture_item(map(), map()) ::
          {:ok, map()} | :malformed | {:write_failed, term()}
  def capture_item(source, item) when is_map(source) and is_map(item) do
    write_item(source, item)
  rescue
    _error -> :malformed
  end

  @doc """
  `capture_item/2` for an HTTP ingest path: a failure in the write path
  raises, so the caller answers with a retryable status and the client sends
  the event again.
  """
  @spec write_item(map(), map()) :: {:ok, map()} | :malformed | {:write_failed, term()}
  def write_item(source, item) when is_map(source) and is_map(item) do
    canonical = canonical_item(item)

    envelope = %{
      "header" => %{
        "key" => nil,
        "sdk" => %{
          "name" => Map.get(item, "sdk_name") || "mcp",
          "version" => Map.get(item, "sdk_version") || "1",
          "platform" => nil
        },
        "sent_at" => nil
      },
      "items" => [canonical]
    }

    with {:ok, raw} <- Jason.encode(envelope), true <- byte_size(raw) <= 1_048_576 do
      case parse(raw) do
        {:ok, parsed, dropped} -> write_items(parsed, source, dropped)
        :malformed -> :malformed
      end
    else
      _ -> :malformed
    end
  end

  defp canonical_item(item) do
    %{
      "id" => Map.get(item, "event_id"),
      "type" => Map.get(item, "type", "message"),
      "timestamp" => Map.get(item, "timestamp"),
      "level" => Map.get(item, "level", "error"),
      "release" => Map.get(item, "release"),
      "environment" => nil,
      "message" => Map.get(item, "message"),
      "exception" => normalize_exception(Map.get(item, "exception")),
      "fingerprint" => Map.get(item, "fingerprint"),
      "breadcrumbs" => Map.get(item, "breadcrumbs"),
      "contexts" => Map.get(item, "contexts"),
      "tags" => Map.get(item, "tags"),
      "user" => Map.get(item, "user"),
      "mechanism" => Map.get(item, "mechanism")
    }
  end

  defp normalize_exception(nil), do: nil

  defp normalize_exception(exception) when is_map(exception) do
    exception
    |> Map.put_new("value", nil)
    |> Map.put_new("stacktrace", nil)
    |> Map.put_new("cause", nil)
  end

  defp normalize_exception(_), do: nil

  defp summarize_writes({:write_failed, reason}, _source), do: {:write_failed, reason}

  defp summarize_writes({:ok, result}, source) do
    if result.quota_dropped > 0, do: AlertRouter.fanout_quota(source.org_id, source.project_id)

    dropped = result.malformed + result.duplicates + result.quota_dropped

    dropped_reason =
      cond do
        dropped == 0 -> nil
        result.quota_dropped > 0 and result.malformed == 0 and result.duplicates == 0 -> "quota"
        result.malformed > 0 and result.duplicates == 0 -> "malformed"
        result.malformed == 0 and result.duplicates > 0 -> "duplicate"
        true -> "mixed"
      end

    {:ok,
     %{
       event_ids: Enum.reverse(result.event_ids),
       dropped: dropped,
       dropped_reason: dropped_reason
     }}
  end

  defp to_event(item, envelope, source) do
    case DateTime.from_iso8601(item["timestamp"]) do
      {:ok, occurred_at, _offset} ->
        case PayloadStore.prepare(item, source.project_id) do
          {:ok, overflow} ->
            exception = item["exception"] || %{}
            overflowed? = not is_nil(overflow)

            {:ok,
             %{
               event_id: item["id"],
               org_id: source.org_id,
               project_id: source.project_id,
               source_id: source.id,
               environment: source.environment,
               occurred_at: occurred_at,
               received_at: DateTime.utc_now(),
               level: item["level"],
               sdk_name: envelope.sdk_name,
               sdk_version: envelope.sdk_version,
               message: item["message"],
               exception_type: exception["type"],
               exception_value: exception["value"],
               frames: symbolicated_frames(exception, source, item["release"]),
               causes: symbolicated_causes(exception, source, item["release"]),
               user_id: get_in(item, ["user", "id"]),
               user_email: get_in(item, ["user", "email"]),
               mechanism: item["mechanism"],
               custom_fingerprint: item["fingerprint"],
               release: item["release"],
               context: unless_overflowed(overflowed?, item["contexts"]),
               tags: unless_overflowed(overflowed?, item["tags"]),
               breadcrumbs: unless_overflowed(overflowed?, item["breadcrumbs"]),
               payload_s3_key: overflow && overflow.key,
               payload_s3_payload: overflow && overflow.payload
             }}

          {:error, _reason} = error ->
            error
        end

      _ ->
        :error
    end
  end

  defp unless_overflowed(true, _value), do: nil
  defp unless_overflowed(false, value), do: value

  defp frames(exception) do
    case get_in(exception, ["stacktrace", "frames"]) do
      frames when is_list(frames) -> Enum.map(frames, &atom_frame/1)
      _ -> nil
    end
  end

  defp symbolicated_frames(exception, source, release),
    do: exception |> frames() |> Alplus.Observe.Symbolicator.symbolicate(source, release)

  defp symbolicated_causes(exception, source, release) do
    case causes(exception) do
      nil ->
        nil

      causes ->
        Enum.map(causes, fn cause ->
          Map.update!(
            cause,
            :frames,
            &Alplus.Observe.Symbolicator.symbolicate(&1, source, release)
          )
        end)
    end
  end

  defp causes(exception) do
    case exception["cause"] do
      cause when is_map(cause) ->
        [
          %{type: cause["type"], value: cause["value"], frames: frames(cause)}
          | causes(cause) || []
        ]

      _ ->
        nil
    end
  end

  defp atom_frame(frame) do
    Enum.reduce(
      [
        {"file", :file},
        {"function", :function},
        {"lineno", :lineno},
        {"colno", :colno},
        {"in_app", :in_app},
        {"pre_context", :pre_context},
        {"context_line", :context_line},
        {"post_context", :post_context}
      ],
      %{},
      fn {wire_key, atom_key}, normalized ->
        case Map.fetch(frame, wire_key) do
          {:ok, value} -> Map.put(normalized, atom_key, value)
          :error -> normalized
        end
      end
    )
  end
end
