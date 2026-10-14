defmodule Alplus.Measure.Referrer do
  @moduledoc """
  Derives the `referrer` dimension (issue #9, Fathom-parity privacy bar):
  host only, never a full URL, never persisted anywhere but the
  `analytics_dimensions` rollup.
  """

  alias Alplus.Measure.OriginAllowlist

  @direct "direct"

  @doc "Direct visitor identifier — no referrer, or a referrer on the project's own site."
  @spec direct :: String.t()
  def direct, do: @direct

  @doc """
  Returns the referrer's host, or `"direct"` when there is no referrer or
  the referrer's host is one of `site_domains` (exact or `*.`-wildcard
  match) — the project's own allow-listed domains, the same list ingest
  already resolves for origin auth. A same-site navigation is not an
  external referral, and reusing that allowlist avoids a public-suffix-list
  dependency: it is the authoritative definition of "this site" already.
  """
  @spec host(String.t() | nil, [String.t()]) :: String.t()
  def host(referrer, site_domains)
      when is_binary(referrer) and is_list(site_domains) and referrer not in ["", "null", @direct] do
    case referrer_hostname(referrer) do
      nil -> @direct
      host -> if OriginAllowlist.allowed?(host, site_domains), do: @direct, else: host
    end
  end

  def host(_referrer, _site_domains), do: @direct

  # Current m.js sends only a hostname. Accepting an absolute URL keeps
  # already-cached script responses valid during their cache lifetime.
  defp referrer_hostname(referrer) do
    OriginAllowlist.origin_hostname(referrer) ||
      case OriginAllowlist.normalize(referrer) do
        {:ok, host} -> host
        {:error, :invalid_hostname} -> nil
      end
  end
end
