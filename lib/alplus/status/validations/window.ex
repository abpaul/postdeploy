defmodule Alplus.Status.Validations.Window do
  @moduledoc false

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    starts_at = Ash.Changeset.get_attribute(changeset, :starts_at)
    ends_at = Ash.Changeset.get_attribute(changeset, :ends_at)

    if match?(%DateTime{}, starts_at) and match?(%DateTime{}, ends_at) and
         DateTime.compare(starts_at, ends_at) == :lt do
      :ok
    else
      {:error, field: :ends_at, message: "must be after the start time"}
    end
  end
end
