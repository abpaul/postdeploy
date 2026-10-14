defmodule Alplus.Monitoring.Validations.SloTarget do
  @moduledoc false

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :slo_target) do
      nil -> :ok
      target when is_integer(target) and target > 0 and target <= 1 -> :ok
      target when is_float(target) and target > 0.0 and target <= 1.0 -> :ok
      _ -> {:error, field: :slo_target, message: "must be greater than 0 and no greater than 1"}
    end
  end
end
