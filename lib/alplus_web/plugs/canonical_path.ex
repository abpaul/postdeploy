defmodule AlplusWeb.Plugs.CanonicalPath do
  @moduledoc """
  Redirects a public URL variant to its one canonical form (PRD §5).

  Without this, `/monitoring` and `/monitoring/` both return 200 with the
  same content. That is two URLs for one page: crawl budget is spent twice,
  and any links that accumulate split between them. The `rel=canonical` tag
  tells a search engine which to prefer, but it is a hint, and it does not
  stop the duplicate being fetched.

  A 301 is the unambiguous answer, and it is safe here because the trailing
  slash never carries meaning in these routes.

  Applied to the marketing pipeline only. It deliberately does not touch:

  * `/` — the one path where a trailing slash *is* the canonical form.
  * Ingest and API paths, where a client is not a browser following
    redirects and a surprise 301 would break a working integration.
  * `/dashboard/*`, which is not indexed and where LiveView owns navigation.

  Query strings are preserved, so an inbound campaign link like
  `/monitoring/?utm_source=x` keeps its attribution through the redirect.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{request_path: path} = conn, _opts) do
    canonical = canonical_path(path)

    if canonical == path do
      conn
    else
      conn
      |> put_resp_header("location", canonical <> query_suffix(conn))
      # 301, not 302: this is a permanent fact about our URL shape, and a
      # temporary redirect would leave both URLs indexable.
      |> resp(301, "")
      |> halt()
    end
  end

  @doc """
  The canonical form of a request path.

  Public so the SEO audit can assert that every URL it knows about is
  already canonical, rather than duplicating the rule.
  """
  @spec canonical_path(String.t()) :: String.t()
  def canonical_path("/"), do: "/"

  def canonical_path(path) do
    case String.trim_trailing(path, "/") do
      "" -> "/"
      trimmed -> trimmed
    end
  end

  defp query_suffix(%Plug.Conn{query_string: ""}), do: ""
  defp query_suffix(%Plug.Conn{query_string: query}), do: "?" <> query
end
