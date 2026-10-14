defmodule Alplus.Analytics.Event do
  @moduledoc """
  Normalizes and validates one incoming product-analytics event (ADR 0007).

  The client sends whatever shape its language makes convenient. This module
  turns that into the fixed row `Alplus.Analytics.Ingest` writes, or returns
  the one error code and message the caller gets back. It registers no
  schema: any property name that fits the bounds in `Alplus.Analytics.Limits`
  is accepted the first time it appears.

  Warning: treat every field here as untrusted input. Nothing in the returned
  struct has been escaped for display; the console escapes at render.
  """

  alias Alplus.Analytics.Limits

  @enforce_keys [:event_name, :distinct_id, :occurred_at, :properties, :client_event_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          event_name: String.t(),
          distinct_id: String.t(),
          occurred_at: DateTime.t(),
          properties: map(),
          client_event_id: String.t() | nil
        }

  @type error :: {:error, code :: String.t(), message :: String.t()}

  # Events with no `distinct_id` all share this one. The count of unique
  # users then reads 1, which is visibly wrong on the Events screen, rather
  # than a fabricated per-event identity that would read as thousands of
  # users and look correct.
  @anonymous_distinct_id "unknown"

  @doc "The identifier used for an event that carried no `distinct_id`."
  @spec anonymous_distinct_id() :: String.t()
  def anonymous_distinct_id, do: @anonymous_distinct_id

  @doc """
  Normalizes one decoded event object against `now`.

  Returns `{:ok, event}` or `{:error, code, message}`, where `code` is the
  stable wire code the API documents (`invalid_event`, `invalid_payload`,
  `invalid_properties`, `invalid_timestamp`).
  """
  @spec normalize(term(), DateTime.t()) :: {:ok, t()} | error()
  def normalize(raw, %DateTime{} = now) when is_map(raw) do
    with {:ok, event_name} <- event_name(raw),
         {:ok, distinct_id} <- distinct_id(raw),
         {:ok, occurred_at} <- occurred_at(raw, now),
         {:ok, properties} <- properties(raw),
         {:ok, client_event_id} <- client_event_id(raw) do
      {:ok,
       %__MODULE__{
         event_name: event_name,
         distinct_id: distinct_id,
         occurred_at: occurred_at,
         properties: properties,
         client_event_id: client_event_id
       }}
    end
  end

  def normalize(_raw, _now),
    do: {:error, "invalid_payload", "each event must be a JSON object"}

  defp event_name(raw) do
    case Map.get(raw, "event") do
      name when is_binary(name) ->
        trimmed = String.trim(name)

        if Limits.valid_event_name?(trimmed) do
          {:ok, trimmed}
        else
          {:error, "invalid_event",
           "event must be 1 to #{Limits.event_name_max_bytes()} characters long and use only letters, digits, and _ . : -"}
        end

      _other ->
        {:error, "invalid_event", "event must be a non-empty string"}
    end
  end

  defp distinct_id(raw) do
    case Map.get(raw, "distinct_id") do
      nil ->
        {:ok, @anonymous_distinct_id}

      id when is_binary(id) ->
        trimmed = String.trim(id)

        cond do
          trimmed == "" ->
            {:ok, @anonymous_distinct_id}

          byte_size(trimmed) > Limits.distinct_id_max_bytes() ->
            {:error, "invalid_payload",
             "distinct_id must be at most #{Limits.distinct_id_max_bytes()} characters"}

          true ->
            {:ok, trimmed}
        end

      _other ->
        {:error, "invalid_payload", "distinct_id must be a string"}
    end
  end

  defp occurred_at(raw, now) do
    case Map.get(raw, "timestamp") do
      nil ->
        {:ok, now}

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, timestamp, _offset} -> within_window(timestamp, now)
          _error -> {:error, "invalid_timestamp", "timestamp must be an RFC 3339 date and time"}
        end

      _other ->
        {:error, "invalid_timestamp", "timestamp must be an RFC 3339 date and time"}
    end
  end

  # A clock that is wrong is refused, never corrected. A silently moved
  # timestamp would land the event in the wrong day of every funnel and
  # retention cohort, and nothing in the product would show why.
  defp within_window(timestamp, now) do
    oldest = DateTime.add(now, -Limits.timestamp_max_age_days() * 86_400, :second)
    newest = DateTime.add(now, Limits.timestamp_max_skew_seconds(), :second)

    cond do
      DateTime.compare(timestamp, oldest) == :lt ->
        {:error, "invalid_timestamp",
         "timestamp must be within the last #{Limits.timestamp_max_age_days()} days"}

      DateTime.compare(timestamp, newest) == :gt ->
        {:error, "invalid_timestamp", "timestamp must not be in the future"}

      true ->
        {:ok, DateTime.truncate(timestamp, :microsecond)}
    end
  end

  defp properties(raw) do
    case Map.get(raw, "properties") do
      nil -> {:ok, %{}}
      properties when is_map(properties) -> normalize_properties(properties)
      _other -> {:error, "invalid_properties", "properties must be a JSON object"}
    end
  end

  defp normalize_properties(properties) do
    if map_size(properties) > Limits.property_max_count() do
      {:error, "invalid_properties",
       "an event carries at most #{Limits.property_max_count()} properties"}
    else
      properties
      |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case normalize_property(key, value) do
          :skip -> {:cont, {:ok, acc}}
          {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
          {:error, _code, _message} = error -> {:halt, error}
        end
      end)
      |> check_encoded_size()
    end
  end

  defp normalize_property(key, value) do
    cond do
      not Limits.valid_property_key?(key) ->
        {:error, "invalid_properties",
         "property names must be 1 to #{Limits.property_key_max_bytes()} characters long and use only letters, digits, and _ . : -"}

      is_nil(value) ->
        :skip

      is_binary(value) ->
        if byte_size(value) > Limits.property_string_max_bytes() do
          {:error, "invalid_properties",
           "property #{key} must be at most #{Limits.property_string_max_bytes()} characters"}
        else
          {:ok, value}
        end

      is_number(value) or is_boolean(value) ->
        {:ok, value}

      # A nested object or list is refused rather than flattened. Breakdowns
      # and filters compare one value to one value, so a nested shape has no
      # meaning anywhere in the product (spec §10: prefer flat properties).
      true ->
        {:error, "invalid_properties", "property #{key} must be text, a number, or true/false"}
    end
  end

  defp check_encoded_size({:ok, properties}) do
    encoded = Jason.encode!(properties)

    if byte_size(encoded) > Limits.properties_max_bytes() do
      {:error, "invalid_properties",
       "properties must be at most #{Limits.properties_max_bytes()} bytes once encoded"}
    else
      {:ok, properties}
    end
  end

  defp check_encoded_size({:error, _code, _message} = error), do: error

  defp client_event_id(raw) do
    case Map.get(raw, "id") do
      nil ->
        {:ok, nil}

      id when is_binary(id) ->
        trimmed = String.trim(id)

        cond do
          trimmed == "" ->
            {:ok, nil}

          byte_size(trimmed) < 4 or byte_size(trimmed) > 64 ->
            {:error, "invalid_payload", "id must be 4 to 64 characters"}

          true ->
            {:ok, trimmed}
        end

      _other ->
        {:error, "invalid_payload", "id must be a string"}
    end
  end
end
