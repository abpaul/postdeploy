defmodule Alplus.Mcp.OAuthAuthorizationCode.Changes.Issue do
  @moduledoc false

  use Ash.Resource.Change

  alias Alplus.Security.BearerToken

  @expiry_seconds 60

  @impl true
  def change(changeset, _opts, _context) do
    {code, hash, prefix} = BearerToken.generate("mcoac")

    changeset
    |> Ash.Changeset.force_change_attribute(:code_hash, hash)
    |> Ash.Changeset.force_change_attribute(:code_prefix, prefix)
    |> Ash.Changeset.force_change_attribute(
      :expires_at,
      DateTime.add(DateTime.utc_now(), @expiry_seconds, :second)
    )
    |> Ash.Changeset.after_action(fn _changeset, authorization_code ->
      {:ok, Ash.Resource.put_metadata(authorization_code, :code, code)}
    end)
  end
end
