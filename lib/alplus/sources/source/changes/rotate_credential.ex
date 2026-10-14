defmodule Alplus.Sources.Source.Changes.RotateCredential do
  @moduledoc """
  Rotates the per-type credential (ADR 0001, decision 5: "reveal once,
  rotate, revoke").

  - `:observe` keeps the *old* secret working until
    `secret_grace_expires_at`, so a deploying client does not get cut off
    mid-rotation.
  - `:measure` has no grace window: its public token is replaced outright,
    so the old value stops resolving to this Source the instant the new
    one is stored.

  `Alplus.Sources.Source.Validations.RotatableType` runs first and rejects
  `:rotate` on a `:monitor` Source, so `change/3` never has to handle it.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case changeset.data.type do
      :observe ->
        grace_period_seconds = Ash.Changeset.get_argument(changeset, :grace_period_seconds)
        {secret, hash, prefix} = Alplus.Security.BearerToken.generate("obs")
        previous_hash = changeset.data.secret_hash
        previous_prefix = changeset.data.secret_prefix

        changeset
        |> Ash.Changeset.force_change_attribute(:secret_hash, hash)
        |> Ash.Changeset.force_change_attribute(:secret_prefix, prefix)
        |> Ash.Changeset.force_change_attribute(:previous_secret_hash, previous_hash)
        |> Ash.Changeset.force_change_attribute(:previous_secret_prefix, previous_prefix)
        |> Ash.Changeset.force_change_attribute(
          :secret_grace_expires_at,
          DateTime.add(DateTime.utc_now(), grace_period_seconds, :second)
        )
        |> Ash.Changeset.after_action(fn _changeset, source ->
          {:ok, Ash.Resource.put_metadata(source, :secret, secret)}
        end)

      :measure ->
        {token, _hash, _prefix} = Alplus.Security.BearerToken.generate("msr")

        changeset
        |> Ash.Changeset.force_change_attribute(:measure_token, token)
        |> Ash.Changeset.after_action(fn _changeset, source ->
          {:ok, Ash.Resource.put_metadata(source, :secret, token)}
        end)

      :changelog ->
        grace_period_seconds = Ash.Changeset.get_argument(changeset, :grace_period_seconds)
        {secret, hash, prefix} = Alplus.Security.BearerToken.generate("chg")
        previous_hash = changeset.data.secret_hash
        previous_prefix = changeset.data.secret_prefix

        changeset
        |> Ash.Changeset.force_change_attribute(:secret_hash, hash)
        |> Ash.Changeset.force_change_attribute(:secret_prefix, prefix)
        |> Ash.Changeset.force_change_attribute(:previous_secret_hash, previous_hash)
        |> Ash.Changeset.force_change_attribute(:previous_secret_prefix, previous_prefix)
        |> Ash.Changeset.force_change_attribute(
          :secret_grace_expires_at,
          DateTime.add(DateTime.utc_now(), grace_period_seconds, :second)
        )
        |> Ash.Changeset.after_action(fn _changeset, source ->
          {:ok, Ash.Resource.put_metadata(source, :secret, secret)}
        end)

      :monitor ->
        changeset
    end
  end
end
