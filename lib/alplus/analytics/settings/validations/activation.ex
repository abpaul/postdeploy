defmodule Alplus.Analytics.Settings.Validations.Activation do
  @moduledoc """
  Validates the activation definition.

  Activation is a two-event measurement, so both names are set together or
  neither is. One name alone would produce a rate with no denominator, and
  the overview would have to invent one.
  """

  use Ash.Resource.Validation

  alias Alplus.Analytics.Limits

  @impl true
  def validate(changeset, _opts, _context) do
    start_event = Ash.Changeset.get_attribute(changeset, :activation_start_event)
    activation_event = Ash.Changeset.get_attribute(changeset, :activation_event)

    cond do
      is_nil(start_event) and is_nil(activation_event) ->
        :ok

      is_nil(start_event) or is_nil(activation_event) ->
        {:error,
         field: :activation_event,
         message: "needs a starting event and an activation event, or neither"}

      not Limits.valid_event_name?(start_event) ->
        {:error, field: :activation_start_event, message: name_message()}

      not Limits.valid_event_name?(activation_event) ->
        {:error, field: :activation_event, message: name_message()}

      start_event == activation_event ->
        {:error, field: :activation_event, message: "must differ from the starting event"}

      true ->
        :ok
    end
  end

  defp name_message do
    "must be an event name of 1 to #{Limits.event_name_max_bytes()} characters, using letters, digits, and _ . : -"
  end
end
