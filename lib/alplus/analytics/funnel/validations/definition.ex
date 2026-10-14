defmodule Alplus.Analytics.Funnel.Validations.Definition do
  @moduledoc """
  Validates a saved funnel's steps, filters, and breakdown property.

  A funnel names event names that ingest could have written, so it applies
  exactly the bounds in `Alplus.Analytics.Limits`. A step list that repeats
  an adjacent name is refused: the second step would match the same event as
  the first and report a meaningless 100% conversion.
  """

  use Ash.Resource.Validation

  alias Alplus.Analytics.Limits

  @impl true
  def validate(changeset, _opts, _context) do
    with :ok <- validate_steps(Ash.Changeset.get_attribute(changeset, :steps)),
         :ok <- validate_filters(Ash.Changeset.get_attribute(changeset, :filters)),
         :ok <- validate_breakdown(Ash.Changeset.get_attribute(changeset, :breakdown_property)) do
      :ok
    else
      {:error, field, message} ->
        {:error, field: field, message: message}
    end
  end

  defp validate_steps(steps) when is_list(steps) do
    bounds = Alplus.Analytics.Funnel.step_bounds()

    cond do
      length(steps) not in bounds ->
        {:error, :steps, "must name between #{bounds.first} and #{bounds.last} events, in order"}

      not Enum.all?(steps, &Limits.valid_event_name?/1) ->
        {:error, :steps,
         "each step must be an event name of 1 to #{Limits.event_name_max_bytes()} characters, using letters, digits, and _ . : -"}

      repeats_adjacent?(steps) ->
        {:error, :steps, "two steps in a row cannot name the same event"}

      true ->
        :ok
    end
  end

  defp validate_steps(_steps), do: {:error, :steps, "must be a list of event names"}

  defp repeats_adjacent?(steps) do
    steps
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [first, second] -> first == second end)
  end

  defp validate_filters(filters) when is_map(filters) do
    cond do
      map_size(filters) > Limits.property_max_count() ->
        {:error, :filters, "must name at most #{Limits.property_max_count()} properties"}

      not Enum.all?(filters, &valid_filter?/1) ->
        {:error, :filters,
         "each filter must name a property and a text, number, or true/false value"}

      true ->
        :ok
    end
  end

  defp validate_filters(_filters), do: {:error, :filters, "must be a set of property values"}

  defp valid_filter?({key, value}) do
    Limits.valid_property_key?(key) and scalar?(value)
  end

  defp scalar?(value) when is_binary(value),
    do: byte_size(value) <= Limits.property_string_max_bytes()

  defp scalar?(value) when is_number(value) or is_boolean(value), do: true
  defp scalar?(_value), do: false

  defp validate_breakdown(nil), do: :ok

  defp validate_breakdown(property) do
    if Limits.valid_property_key?(property) do
      :ok
    else
      {:error, :breakdown_property,
       "must be a property name of 1 to #{Limits.property_key_max_bytes()} characters"}
    end
  end
end
