defmodule Alplus.Mcp.OAuthAccessToken.Changes.Issue do
  @moduledoc false

  use Ash.Resource.Change

  alias Alplus.Security.BearerToken

  # One hour. A ten-minute token made every long-running MCP client refresh
  # about 144 times a day, and each refresh can lose its response.
  @expiry_seconds 3600

  @impl true
  def change(changeset, _opts, _context) do
    {token, hash, prefix} = BearerToken.generate("mcoat")

    changeset
    |> Ash.Changeset.force_change_attribute(:token_hash, hash)
    |> Ash.Changeset.force_change_attribute(:token_prefix, prefix)
    |> Ash.Changeset.force_change_attribute(
      :expires_at,
      DateTime.add(DateTime.utc_now(), @expiry_seconds, :second)
    )
    |> Ash.Changeset.after_action(fn _changeset, access_token ->
      {:ok, Ash.Resource.put_metadata(access_token, :token, token)}
    end)
  end
end
