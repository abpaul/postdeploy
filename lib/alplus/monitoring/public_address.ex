defmodule Alplus.Monitoring.PublicAddress do
  @moduledoc false
  import Bitwise

  @type address :: :inet.ip_address()
  @type resolver :: (String.t() -> {:ok, [address()]} | {:error, term()})

  @doc false
  @spec resolve(String.t(), resolver() | nil) :: {:ok, address()} | {:error, atom()}
  def resolve(host, resolver \\ nil) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} ->
        validate([address])

      {:error, _reason} ->
        case resolve_hostname(host, resolver) do
          {:ok, addresses} when is_list(addresses) -> validate(addresses)
          {:ok, address} when is_tuple(address) -> validate([address])
          _ -> {:error, :dns_error}
        end
    end
  end

  @doc false
  @spec global?(address()) :: boolean()
  def global?(address) when tuple_size(address) == 4, do: global_ipv4?(address)
  def global?(address) when tuple_size(address) == 8, do: global_ipv6?(address)
  def global?(_address), do: false

  defp validate([]), do: {:error, :dns_error}

  defp validate(addresses) do
    if Enum.all?(addresses, &global?/1) do
      {:ok, List.first(addresses)}
    else
      {:error, :forbidden_address}
    end
  end

  defp resolve_hostname(host) do
    addresses =
      for family <- [:inet, :inet6], reduce: [] do
        addresses ->
          case :inet.getaddrs(String.to_charlist(host), family) do
            {:ok, family_addresses} -> addresses ++ family_addresses
            {:error, _reason} -> addresses
          end
      end

    if addresses == [], do: {:error, :dns_error}, else: {:ok, addresses}
  end

  defp resolve_hostname(host, nil), do: resolve_hostname(host)
  defp resolve_hostname(host, resolver), do: resolver.(host)

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp global_ipv4?({a, b, c, d}) do
    value = (a <<< 24) + (b <<< 16) + (c <<< 8) + d

    not in_range?(value, 0x00000000, 0x00FFFFFF) and
      not in_range?(value, 0x0A000000, 0x0AFFFFFF) and
      not in_range?(value, 0x64400000, 0x647FFFFF) and
      not in_range?(value, 0x7F000000, 0x7FFFFFFF) and
      not in_range?(value, 0xA9FE0000, 0xA9FEFFFF) and
      not in_range?(value, 0xAC100000, 0xAC1FFFFF) and
      not in_range?(value, 0xC0000000, 0xC00000FF) and
      not in_range?(value, 0xC0000200, 0xC00002FF) and
      not in_range?(value, 0xC0586300, 0xC05863FF) and
      not in_range?(value, 0xC0A80000, 0xC0A8FFFF) and
      not in_range?(value, 0xC6120000, 0xC613FFFF) and
      not in_range?(value, 0xC6336400, 0xC63364FF) and
      not in_range?(value, 0xCB007100, 0xCB0071FF) and
      not in_range?(value, 0xE0000000, 0xEFFFFFFF) and
      not in_range?(value, 0xF0000000, 0xFFFFFFFF)
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp global_ipv6?({a, b, c, d, e, f, g, h}) do
    value =
      Enum.reduce([a, b, c, d, e, f, g, h], 0, fn part, value ->
        (value <<< 16) + part
      end)

    cond do
      ipv4_mapped?(value) ->
        global_ipv4?(ipv4_from_mapped(value))

      not prefix?(value, 1, 3) ->
        false

      prefix?(value, 0x4002000, 29) ->
        false

      prefix?(value, 0x200100010000, 48) ->
        false

      prefix?(value, 0x200100020000, 48) ->
        false

      prefix?(value, 0x20010003, 32) ->
        false

      prefix?(value, 0x200100040112, 48) ->
        false

      prefix?(value, 0x2001001, 28) ->
        false

      prefix?(value, 0x2001002, 28) ->
        false

      prefix?(value, 0x20010DB8, 32) ->
        false

      prefix?(value, 0x2002, 16) ->
        false

      prefix?(value, 0x3FFF0, 20) ->
        false

      prefix?(value, 0x64FF9B000000, 96) ->
        false

      prefix?(value, 0x64FF9B000001, 48) ->
        false

      true ->
        true
    end
  end

  defp ipv4_mapped?(value),
    do: in_range?(value, 0x00000000000000000000FFFF00000000, 0x00000000000000000000FFFFFFFFFFFF)

  defp ipv4_from_mapped(value) do
    value = value &&& 0xFFFFFFFF
    {value >>> 24 &&& 0xFF, value >>> 16 &&& 0xFF, value >>> 8 &&& 0xFF, value &&& 0xFF}
  end

  defp in_range?(value, min, max), do: value >= min and value <= max

  defp prefix?(value, prefix, bits), do: value >>> (128 - bits) == prefix
end
