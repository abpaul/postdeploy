defmodule Alplus.Analytics.Ingest do
  @moduledoc """
  Parses, meters, and writes product-analytics events (ADR 0007).

  The public endpoint does five things and nothing else: authenticate,
  validate, rate-limit, write, respond. No funnel, retention, or property
  aggregate is computed here.

  Direct SQL, not an Ash action per event: this is a hot path writing up to
  100 rows per request (`docs/DIRECT-ECTO-ESCAPE-HATCHES.md`). Both
  statements carry the org and project the authenticated Source resolves to,
  so a payload can never name another tenant.

  Delivery is at-least-once. A retry that repeats the client's `id` writes
  nothing the second time, because `product_events_project_client_id_index`
  refuses the duplicate and the insert skips it.
  """

  require Logger

  alias Alplus.Analytics.{Event, Limits}

  # The registry write is bounded per request as well as per event name. A
  # batch could otherwise name 100 events by 40 properties, and the cap check
  # runs once per pair.
  @max_registry_pairs_per_request 400
  alias Alplus.Billing.EventMeter
  alias Alplus.Id
  alias Alplus.Repo

  @type result :: %{
          accepted: non_neg_integer(),
          dropped: non_neg_integer(),
          dropped_reason: String.t() | nil
        }

  @doc """
  Decodes one ingest request body into a list of raw event objects.

  `:single` accepts one object; `:batch` accepts `{"events": [...]}`. Both
  return the stable wire error code on a malformed body.
  """
  @spec parse(binary(), :single | :batch) ::
          {:ok, [map()]} | {:error, String.t(), String.t()}
  def parse(body, shape) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> extract(decoded, shape)
      {:error, _reason} -> {:error, "invalid_payload", "body must be valid JSON"}
    end
  end

  defp extract(decoded, :single) when is_map(decoded), do: {:ok, [decoded]}

  defp extract(_decoded, :single),
    do: {:error, "invalid_payload", "body must be a JSON object"}

  defp extract(%{"events" => events}, :batch) when is_list(events) do
    cond do
      events == [] ->
        {:error, "invalid_payload", "events must contain at least one event"}

      length(events) > Limits.batch_max_events() ->
        {:error, "batch_too_large", "a batch carries at most #{Limits.batch_max_events()} events"}

      true ->
        {:ok, events}
    end
  end

  defp extract(_decoded, :batch),
    do: {:error, "invalid_payload", "body must be a JSON object with an events array"}

  @doc """
  Validates every raw event, refusing the whole request on the first bad one.

  A partially accepted batch would leave the caller unable to say which
  events it still has to send, so validation is all-or-nothing. Quota is not:
  see `write/3`.
  """
  @spec normalize([map()], DateTime.t()) ::
          {:ok, [Event.t()]} | {:error, String.t(), String.t()}
  def normalize(raw_events, %DateTime{} = now) do
    raw_events
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case Event.normalize(raw, now) do
        {:ok, event} -> {:cont, {:ok, [event | acc]}}
        {:error, _code, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  end

  @doc """
  Meters and writes `events` for the authenticated `source`.

  `source.environment` is the only environment written, never a
  client-supplied field (ARCHITECTURE.md §4). Over the package's grace
  ceiling the meter accepts the prefix that still fits and the rest are
  dropped and counted, so the customer sees a real usage number rather than
  a silent stop.
  """
  @spec write(Alplus.Sources.Source.t(), [Event.t()], DateTime.t()) ::
          {:ok, result()} | {:error, :write_failed}
  def write(source, events, now \\ DateTime.utc_now())

  def write(_source, [], _now), do: {:ok, %{accepted: 0, dropped: 0, dropped_reason: nil}}

  def write(source, events, now) do
    requested = length(events)
    decision = EventMeter.consume(source.org_id, :product_events, now, requested)
    accepted = Enum.take(events, decision.accepted)
    dropped = requested - decision.accepted

    case insert(source, accepted, now) do
      :ok ->
        {:ok,
         %{
           accepted: decision.accepted,
           dropped: dropped,
           dropped_reason: if(dropped > 0, do: "quota")
         }}

      {:error, reason} ->
        Logger.error("product analytics write failed: #{inspect(reason)}")
        {:error, :write_failed}
    end
  end

  defp insert(_source, [], _now), do: :ok

  defp insert(source, events, now) do
    Repo.transaction(fn ->
      insert_events!(source, events, now)
      register_property_keys!(source, events)
    end)
    |> case do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, error}
  end

  # One multi-row insert for the whole request. `ON CONFLICT DO NOTHING`
  # covers the deduplication index, so a replayed batch costs one statement
  # and writes nothing.
  # `placeholders` is a generated list of `$n` groups and nothing else. Every
  # event field is a bound parameter.
  # sobelow_skip ["SQL.Query"]
  defp insert_events!(source, events, now) do
    {placeholders, params} = build_rows(source, events, now)

    Repo.query!(
      """
      INSERT INTO product_events
        (id, org_id, project_id, source_id, environment, event_name, distinct_id,
         occurred_at, received_at, properties, client_event_id)
      VALUES #{placeholders}
      ON CONFLICT DO NOTHING
      """,
      params
    )
  end

  defp build_rows(source, events, now) do
    {placeholder_groups, params, _next} =
      Enum.reduce(events, {[], [], 1}, fn event, {groups, params, index} ->
        group =
          index..(index + 10)
          |> Enum.map_join(", ", &"$#{&1}")
          |> then(&"(#{&1})")

        row = [
          Id.generate(:product_event),
          source.org_id,
          source.project_id,
          source.id,
          source.environment,
          event.event_name,
          event.distinct_id,
          event.occurred_at,
          now,
          event.properties,
          event.client_event_id
        ]

        {[group | groups], params ++ row, index + 11}
      end)

    {placeholder_groups |> Enum.reverse() |> Enum.join(", "), params}
  end

  # The breakdown and filter pickers read this registry rather than scanning
  # events for distinct property names.
  #
  # One statement, never one per property. A 100-event batch may name 40
  # properties on each event, and a statement per pair meant 4,000 round
  # trips holding an ingest connection and a write transaction open, on a
  # path whose key is published inside the customer's application.
  #
  # The row cap per event name lives in the statement, so a client that
  # invents a property name per request stops growing the registry instead of
  # filling it. The cap gates only NEW names: a key already in the registry
  # always refreshes its `last_seen_at`, or retention would delete the whole
  # picker for a busy event ninety days after it reached the cap.
  defp register_property_keys!(source, events) do
    pairs =
      events
      |> Enum.flat_map(fn event ->
        Enum.map(Map.keys(event.properties), &{event.event_name, &1})
      end)
      |> Enum.uniq()
      |> Enum.take(@max_registry_pairs_per_request)

    case pairs do
      [] ->
        :ok

      pairs ->
        {event_names, property_keys} = Enum.unzip(pairs)

        Repo.query!(
          """
          INSERT INTO product_event_property_keys
            (org_id, project_id, event_name, property_key, last_seen_at)
          SELECT $1, $2, pair.event_name, pair.property_key, now()
          FROM unnest($3::text[], $4::text[]) AS pair(event_name, property_key)
          WHERE EXISTS (
            SELECT 1 FROM product_event_property_keys known
            WHERE known.project_id = $2
              AND known.event_name = pair.event_name
              AND known.property_key = pair.property_key
          ) OR (
            SELECT count(*) FROM product_event_property_keys existing
            WHERE existing.project_id = $2 AND existing.event_name = pair.event_name
          ) < $5
          ON CONFLICT (project_id, event_name, property_key)
          DO UPDATE SET last_seen_at = now()
          """,
          [
            source.org_id,
            source.project_id,
            event_names,
            property_keys,
            Limits.property_keys_per_event()
          ]
        )

        :ok
    end
  end
end
