defmodule Alplus.Sources.Source.Changes.NormalizeHostname do
  @moduledoc "Normalizes and validates the browser origin stored on a Measure Source."

  use Ash.Resource.Change

  alias Alplus.Measure.OriginAllowlist

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :hostname) do
      hostname when is_binary(hostname) ->
        case OriginAllowlist.normalize(hostname) do
          {:ok, normalized} ->
            Ash.Changeset.force_change_attribute(changeset, :hostname, normalized)

          {:error, :invalid_hostname} ->
            Ash.Changeset.add_error(changeset,
              field: :hostname,
              message: "must be a valid hostname"
            )
        end

      _missing ->
        Ash.Changeset.add_error(changeset,
          field: :hostname,
          message: "must be a valid hostname"
        )
    end
  end
end
