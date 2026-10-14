defmodule Alplus.Sources.Source.Changes.MintCredential do
  @moduledoc """
  Mints the per-type ingest credential on Source creation (ADR 0001,
  decision 8: "mint a new per-Source token", never reuse
  `project.public_token`).

  - `:observe` gets a secret ingest key: only the SHA-256 hash and an
    8-character prefix are stored, the plaintext is returned once via the
    `:secret` action metadata.
  - `:measure` gets a public token stored in the clear (not a secret) —
    it identifies the Source in `GET /m.js` snippets, so there is nothing
    to hide.
  - `:monitor` is pull-based and mints no ingest credential.
  - `:changelog` gets a secret draft-authoring key.
  - `:analytics` gets a write-only product analytics key (`pda_*`). It is
    stored and returned exactly like the Observe key, because it is a secret
    the customer ships inside a client: the hash is what PostDeploy keeps
    (ADR 0007).
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :type) do
      :observe ->
        {secret, hash, prefix} = Alplus.Security.BearerToken.generate("obs")

        changeset
        |> Ash.Changeset.force_change_attribute(:secret_hash, hash)
        |> Ash.Changeset.force_change_attribute(:secret_prefix, prefix)
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

      :analytics ->
        {secret, hash, prefix} = Alplus.Security.BearerToken.generate("pda")

        changeset
        |> Ash.Changeset.force_change_attribute(:secret_hash, hash)
        |> Ash.Changeset.force_change_attribute(:secret_prefix, prefix)
        |> Ash.Changeset.after_action(fn _changeset, source ->
          {:ok, Ash.Resource.put_metadata(source, :secret, secret)}
        end)

      :changelog ->
        {secret, hash, prefix} = Alplus.Security.BearerToken.generate("chg")

        changeset
        |> Ash.Changeset.force_change_attribute(:secret_hash, hash)
        |> Ash.Changeset.force_change_attribute(:secret_prefix, prefix)
        |> Ash.Changeset.after_action(fn _changeset, source ->
          {:ok, Ash.Resource.put_metadata(source, :secret, secret)}
        end)

      :monitor ->
        changeset

      # `AshPhoenix.Form.for_create/3` runs this change immediately at
      # form-build time, before any params exist (`:type` still `nil`) —
      # not only at submit. The `:create` action's `allow_nil? false` on
      # `:type` still rejects a real submission with no type.
      nil ->
        changeset
    end
  end
end
