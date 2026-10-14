defmodule Alplus.Turnstile do
  @moduledoc """
  Cloudflare Turnstile testing-key detection.

  Server-side verification uses `Alplus.Turnstile.Client` directly.
  """

  # Cloudflare's documented testing keys. The site keys render a widget
  # stamped "For testing only. If seen, report to site owner", and the secret
  # `1x...AA` validates *any* response token. Production ran on this pair, so
  # the sign-up form looked healthy while its bot protection was a no-op:
  # every submission verified, whatever it sent.
  #
  # Visible only to someone who looks at the widget, which is why this is
  # asserted at boot (config/runtime.exs) rather than left to a reviewer.
  @dummy_keys ~w(
    1x00000000000000000000AA
    1x00000000000000000000BB
    2x00000000000000000000AB
    2x00000000000000000000BB
    3x00000000000000000000FF
    1x0000000000000000000000000000000AA
    2x0000000000000000000000000000000AA
    3x0000000000000000000000000000000AA
  )

  @doc """
  Whether `key` is one of Cloudflare's testing site or secret keys.

  Also matches by shape, not only the published list: every dummy key is
  `1x`/`2x`/`3x` followed by zeroes, while a real key starts `0x4A`.
  """
  @spec dummy_key?(String.t() | nil) :: boolean()
  def dummy_key?(key) when is_binary(key) do
    key in @dummy_keys or String.match?(key, ~r/\A[123]x0{8,}[A-Z]{2}\z/)
  end

  def dummy_key?(_key), do: false
end
