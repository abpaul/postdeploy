defmodule Alplus.PublicToken do
  @moduledoc """
  Generates opaque, URL-safe public identifiers.

  Public tokens identify organizations and projects in console URLs. They are
  deliberately separate from primary keys, so internal ids never leak through
  browser navigation.
  """

  @alphabet "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
  @length 16

  @doc "Returns a cryptographically random 16-character Base62 token."
  @spec generate() :: String.t()
  def generate, do: generate(@length, [])

  defp generate(0, chars), do: chars |> Enum.reverse() |> IO.iodata_to_binary()

  defp generate(remaining, chars) do
    <<byte>> = :crypto.strong_rand_bytes(1)

    if byte < 248 do
      generate(remaining - 1, [binary_part(@alphabet, rem(byte, 62), 1) | chars])
    else
      generate(remaining, chars)
    end
  end
end
