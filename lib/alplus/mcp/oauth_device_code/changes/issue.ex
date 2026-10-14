defmodule Alplus.Mcp.OAuthDeviceCode.Changes.Issue do
  @moduledoc false

  use Ash.Resource.Change

  alias Alplus.Security.BearerToken

  # RFC 8628 suggests a lifetime long enough for a person to move to another
  # device, read the code, and sign in.
  @expiry_seconds 900

  @impl true
  def change(changeset, _opts, _context) do
    {device_code, hash, prefix} = BearerToken.generate("mcodc")

    changeset
    |> Ash.Changeset.force_change_attribute(:device_code_hash, hash)
    |> Ash.Changeset.force_change_attribute(:device_code_prefix, prefix)
    |> Ash.Changeset.force_change_attribute(
      :expires_at,
      DateTime.add(DateTime.utc_now(), @expiry_seconds, :second)
    )
    |> Ash.Changeset.after_action(fn _changeset, device_code_record ->
      {:ok, Ash.Resource.put_metadata(device_code_record, :device_code, device_code)}
    end)
  end

  @doc "Lifetime of a device authorization request, in seconds."
  @spec expiry_seconds() :: pos_integer()
  def expiry_seconds, do: @expiry_seconds
end
