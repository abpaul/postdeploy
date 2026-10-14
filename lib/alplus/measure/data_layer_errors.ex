defmodule Alplus.Measure.DataLayerErrors do
  @moduledoc """
  Classifies an exception raised by a durable read as a database outage or not.

  Only a confirmed database cause becomes a Measure dashboard's `unavailable`
  state. Everything else is a bug and keeps raising, so a broken query is
  never reported to a reader as "temporarily unavailable".
  """

  @database_outage_text [
    "** (DBConnection.ConnectionError)",
    "** (Postgrex.Error)",
    "** (Ash.Error.Invalid.Unavailable)"
  ]

  @doc "Whether `error` is a confirmed database outage rather than a bug."
  def unavailable?(%Ash.Error.Unknown{errors: errors}),
    do: Enum.any?(errors, &unavailable?/1)

  def unavailable?(%Ash.Error.Unknown.UnknownError{error: error}),
    do: unavailable?(error)

  def unavailable?(%Ash.Error.Invalid.Unavailable{}), do: true
  def unavailable?(%DBConnection.ConnectionError{}), do: true
  def unavailable?(%Postgrex.Error{}), do: true

  # Ash formats a wrapped exception to text before it reaches here, so the
  # exception name the formatter printed is the only surviving evidence of the
  # cause. Nothing but those three names counts.
  def unavailable?(message) when is_binary(message),
    do: message |> String.trim_leading() |> String.starts_with?(@database_outage_text)

  def unavailable?(_error), do: false
end
