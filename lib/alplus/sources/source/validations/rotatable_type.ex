defmodule Alplus.Sources.Source.Validations.RotatableType do
  @moduledoc """
  Rejects `:rotate` on a `:monitor` Source. Monitor Sources are pull-based
  and mint no ingest credential (ADR 0001), so there is nothing to rotate.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case changeset.data.type do
      :monitor ->
        {:error, field: :type, message: "a monitor source has no credential to rotate"}

      _ ->
        :ok
    end
  end
end
