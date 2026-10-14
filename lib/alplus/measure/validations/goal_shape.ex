defmodule Alplus.Measure.Validations.GoalShape do
  @moduledoc false

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    kind = Ash.Changeset.get_attribute(changeset, :kind)
    path = Ash.Changeset.get_attribute(changeset, :path)
    event_name = Ash.Changeset.get_attribute(changeset, :event_name)

    case {kind, path, event_name} do
      {"pageview", path, nil} when is_binary(path) and byte_size(path) in 1..2048 ->
        :ok

      {"event", nil, name} when is_binary(name) ->
        validate_event_name(name)

      _ ->
        {:error, field: :kind, message: "must have exactly one matching page path or event name"}
    end
  end

  defp validate_event_name(name) do
    if Regex.match?(~r/^[a-z0-9_-]{1,64}$/, name) do
      :ok
    else
      {:error, field: :event_name, message: "must match [a-z0-9_-]{1,64}"}
    end
  end
end
