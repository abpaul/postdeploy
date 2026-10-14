defmodule AlplusWeb.Plugs.AcquisitionAttribution do
  @moduledoc """
  Records how a visitor first arrived, so organic acquisition can be
  measured through to activation rather than guessed at.

  Deliberately narrow, because PostDeploy sells a privacy-first analytics product
  and cannot run invasive tracking on its own marketing site:

  * First touch only. The first public page of a session is stored and
    never overwritten, so the landing page that earned the signup is the
    one credited, not the last page before the form.
  * Session-scoped. It lives in the existing signed session cookie, which
    the visitor already has, and dies with it. No new cookie, no
    cross-site identifier, no third party.
  * No personal data. Landing path, referrer host, and UTM tags. The
    referrer is reduced to its host, so a full URL with a query string
    never lands in our database.
  * Only public marketing pages. Authenticated console requests are never
    a landing page.

  `Alplus.Growth.record_signup_attribution/2` reads this at registration and
  writes one row. Nothing else consumes it.
  """

  @behaviour Plug

  @session_key "acquisition"

  # Kept short and fixed. An arbitrary query string must never become a
  # column, and these are the tags every ad and campaign tool already uses.
  @utm_params ~w(utm_source utm_medium utm_campaign utm_content utm_term)

  # Bounds what a crafted link can push into the session cookie.
  @max_value_length 120

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    # First touch wins: once recorded, never replaced.
    if Plug.Conn.get_session(conn, @session_key) do
      conn
    else
      Plug.Conn.put_session(conn, @session_key, attribution(conn))
    end
  end

  @doc "The session key, for readers of the attribution map."
  def session_key, do: @session_key

  defp attribution(conn) do
    %{
      "landing_page" => conn.request_path,
      "referrer_host" => referrer_host(conn),
      "utm" => utm(conn),
      "first_seen_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # Host only, never the full referring URL: the path and query of the page
  # someone came from is their business, and the host is all that is needed
  # to tell a search engine from a forum from a direct visit.
  defp referrer_host(conn) do
    with [referrer | _] <- Plug.Conn.get_req_header(conn, "referer"),
         %URI{host: host} when is_binary(host) <- URI.parse(referrer) do
      truncate(host)
    else
      _ -> nil
    end
  end

  defp utm(conn) do
    conn = Plug.Conn.fetch_query_params(conn)

    @utm_params
    |> Enum.reduce(%{}, fn param, acc ->
      case Map.get(conn.query_params, param) do
        value when is_binary(value) and value != "" -> Map.put(acc, param, truncate(value))
        _ -> acc
      end
    end)
  end

  defp truncate(value), do: String.slice(value, 0, @max_value_length)
end
