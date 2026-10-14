defmodule Alplus.Monitoring.HeartbeatConfig.Changes.IssueToken do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    {token, hash, prefix} = Alplus.Security.BearerToken.generate("hb")

    changeset
    |> Ash.Changeset.force_change_attribute(:heartbeat_token_hash, hash)
    |> Ash.Changeset.force_change_attribute(:heartbeat_token_prefix, prefix)
    |> Ash.Changeset.after_action(fn _changeset, config ->
      {:ok, Ash.Resource.put_metadata(config, :heartbeat_token, token)}
    end)
  end
end
