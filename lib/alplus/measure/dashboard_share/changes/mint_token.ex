defmodule Alplus.Measure.DashboardShare.Changes.MintToken do
  @moduledoc false

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    {token, hash, prefix} = Alplus.Security.BearerToken.generate("shr")

    changeset
    |> Ash.Changeset.force_change_attribute(:token_hash, hash)
    |> Ash.Changeset.force_change_attribute(:token_prefix, prefix)
    |> Ash.Changeset.after_action(fn _changeset, share ->
      {:ok, Ash.Resource.put_metadata(share, :token, token)}
    end)
  end
end
