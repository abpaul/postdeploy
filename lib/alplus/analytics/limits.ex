defmodule Alplus.Analytics.Limits do
  @moduledoc """
  The one definition of every product-analytics input bound (ADR 0007).

  Ingest validation, the saved-funnel validation, the MCP schemas, and the
  published documentation all read these values, so a limit can only be
  changed in one place. Each bound also exists as a PostgreSQL CHECK, so a
  path that skipped validation still cannot write an oversized row.
  """

  # Long enough for `subscription_renewal_reminder_sent`, short enough that
  # an accidentally interpolated identifier is rejected rather than stored.
  @event_name_max_bytes 120
  @event_name_format ~r/^[A-Za-z0-9][A-Za-z0-9_.:-]*$/

  @distinct_id_max_bytes 200

  @property_max_count 40
  @property_key_max_bytes 64
  @property_key_format ~r/^[A-Za-z0-9][A-Za-z0-9_.:-]*$/
  @property_string_max_bytes 512
  @properties_max_bytes 8192

  # A registry row per property name per event name. Past this, ingest keeps
  # storing the events and stops registering new names, so a client that
  # invents a property name per request cannot grow the picker without bound.
  @property_keys_per_event 200

  @batch_max_events 100
  @request_max_bytes 262_144

  # How far out of step with the server a client clock may be. Outside it the
  # event is refused rather than silently moved, so a broken clock is visible.
  @timestamp_max_age_days 30
  @timestamp_max_skew_seconds 3600

  # Breakdown and filter picker bounds. The breakdown query orders by count
  # and buckets the tail into `(other)`, so a high-cardinality property
  # degrades to one honest row instead of thousands.
  @breakdown_max_values 20
  @live_events_limit 100
  @live_events_window_minutes 60

  def event_name_max_bytes, do: @event_name_max_bytes
  def event_name_format, do: @event_name_format
  def distinct_id_max_bytes, do: @distinct_id_max_bytes
  def property_max_count, do: @property_max_count
  def property_key_max_bytes, do: @property_key_max_bytes
  def property_key_format, do: @property_key_format
  def property_string_max_bytes, do: @property_string_max_bytes
  def properties_max_bytes, do: @properties_max_bytes
  def property_keys_per_event, do: @property_keys_per_event
  def batch_max_events, do: @batch_max_events
  def request_max_bytes, do: @request_max_bytes
  def timestamp_max_age_days, do: @timestamp_max_age_days
  def timestamp_max_skew_seconds, do: @timestamp_max_skew_seconds
  def breakdown_max_values, do: @breakdown_max_values
  def live_events_limit, do: @live_events_limit
  def live_events_window_minutes, do: @live_events_window_minutes

  @doc """
  Returns `:ok` when `name` is a usable event name.

  The same check guards ingest and every saved definition, so a funnel can
  never name a step that ingest would refuse to write.
  """
  @spec valid_event_name?(term()) :: boolean()
  def valid_event_name?(name) when is_binary(name) do
    byte_size(name) > 0 and byte_size(name) <= @event_name_max_bytes and
      Regex.match?(@event_name_format, name)
  end

  def valid_event_name?(_name), do: false

  @doc "Returns `true` when `key` is a usable property name."
  @spec valid_property_key?(term()) :: boolean()
  def valid_property_key?(key) when is_binary(key) do
    byte_size(key) > 0 and byte_size(key) <= @property_key_max_bytes and
      Regex.match?(@property_key_format, key)
  end

  def valid_property_key?(_key), do: false
end
