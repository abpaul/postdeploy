defmodule Alplus.Accounts.SessionActivity do
  @moduledoc """
  Pure decision logic for the 7-day inactivity window layered on top of
  the token's 30-day absolute lifetime (ARCHITECTURE.md §10).

  Kept separate from `AlplusWeb.Router`'s plug so the decision (given a
  last-seen timestamp and "now", is the session expired?) can be unit
  tested with a fixed clock instead of faking session cookies end to end.
  """

  @inactivity_seconds 7 * 24 * 60 * 60

  @doc "Returns `true` if a session last active at `last_seen_at` (unix seconds) is now expired."
  @spec expired?(integer() | nil, integer()) :: boolean()
  def expired?(last_seen_at, now)
  def expired?(nil, _now), do: false
  def expired?(last_seen_at, now), do: now - last_seen_at > @inactivity_seconds
end
