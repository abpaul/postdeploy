defmodule Alplus.Mcp.OAuthRefreshToken.Changes.Issue do
  @moduledoc false

  use Ash.Resource.Change

  alias Alplus.Security.BearerToken

  @expiry_seconds 60 * 60 * 24 * 30

  @impl true
  def change(changeset, _opts, _context) do
    {token, hash, prefix} = BearerToken.generate("mcort")

    changeset
    |> Ash.Changeset.force_change_attribute(:token_hash, hash)
    |> Ash.Changeset.force_change_attribute(:token_prefix, prefix)
    |> Ash.Changeset.force_change_attribute(
      :expires_at,
      DateTime.add(DateTime.utc_now(), @expiry_seconds, :second)
    )
    |> Ash.Changeset.after_action(fn _changeset, refresh_token ->
      {:ok, Ash.Resource.put_metadata(refresh_token, :token, token)}
    end)
  end
end
