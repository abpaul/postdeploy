defmodule Alplus.Security.BearerToken do
  @moduledoc """
  Random capability secrets (ARCHITECTURE.md §5, §14 rule 2): `alp_*` API
  keys, invitation tokens, and anything else that is "possession proves
  authorization." Only the SHA-256 hash is ever persisted; the raw secret
  is generated, returned once, and never stored.

  Never implement hashing or randomness for a new bearer secret by hand —
  use this module so every capability token in PostDeploy is generated and hashed
  the same way.
  """

  @random_bytes 32

  # Sentry SDKs read the DSN public key as `\w+`, so an Observe key must hold
  # no `-`, which base64url otherwise produces.
  @word_character_prefixes ["obs"]

  @doc """
  Generates a prefixed bearer secret, e.g. `generate("alp")` ->
  `{"alp_9f2c...", "<sha256 hex>", "9f2c8a1b"}` — `{secret, hash,
  short_prefix}`. `short_prefix` is the first 8 characters after the
  prefix, safe to store and display so a user can recognize which key is
  which without ever seeing the secret again.
  """
  @spec generate(String.t()) :: {String.t(), String.t(), String.t()}
  def generate(prefix) when is_binary(prefix) do
    random = random_for(prefix)
    secret = prefix <> "_" <> random
    {secret, hash(secret), String.slice(random, 0, 8)}
  end

  @doc "Generates an unprefixed bearer secret. Returns `{secret, hash}`."
  @spec generate() :: {String.t(), String.t()}
  def generate do
    secret = random_string()
    {secret, hash(secret)}
  end

  @doc "Hex-encoded SHA-256 of `secret`, for storage."
  @spec hash(String.t()) :: String.t()
  def hash(secret) when is_binary(secret) do
    :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
  end

  @doc """
  Returns the short prefix of an already-issued secret, so a lookup can
  find the row without querying by the hash. `short_prefix("alp_9f2c8a1b…")`
  -> `"9f2c8a1b"`. Returns `nil` when `secret` has no `_` separator.
  """
  @spec short_prefix(String.t()) :: String.t() | nil
  def short_prefix(secret) when is_binary(secret) do
    case String.split(secret, "_", parts: 2) do
      [_prefix, random] when byte_size(random) >= 8 -> String.slice(random, 0, 8)
      _ -> nil
    end
  end

  @doc """
  Compares two hashes in constant time. Use this instead of `==` so a
  timing difference cannot reveal how much of a hash an attacker guessed.
  """
  @spec matches?(String.t() | nil, String.t() | nil) :: boolean()
  def matches?(hash_a, hash_b) when is_binary(hash_a) and is_binary(hash_b) do
    Plug.Crypto.secure_compare(hash_a, hash_b)
  end

  def matches?(_hash_a, _hash_b), do: false

  defp random_for(prefix) when prefix in @word_character_prefixes do
    random = random_string()
    if String.contains?(random, "-"), do: random_for(prefix), else: random
  end

  defp random_for(_prefix), do: random_string()

  defp random_string do
    :crypto.strong_rand_bytes(@random_bytes) |> Base.url_encode64(padding: false)
  end
end
