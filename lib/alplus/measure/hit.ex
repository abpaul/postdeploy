defmodule Alplus.Measure.Hit do
  @moduledoc """
  Referrer comes from the `"referrer"` field in the `/m` beacon body
  (`document.referrer`, set by `m.js`), not the HTTP `Referer` header —
  `sendBeacon`/`fetch` don't reliably carry that header cross-origin, so
  the client-supplied value is the correct source for this beacon.

  `normalize/1` carries the raw referrer through only as far as
  `Alplus.Measure.Ingest`, which resolves it to `referrer_host` against the
  project's allow-listed domains (the same list already used for origin
  auth) and discards the raw value before anything is persisted.
  """

  @visit_ttl_ms :timer.minutes(30)

  def normalize(%{"url" => url} = body) when is_binary(url) and byte_size(url) in 1..2048 do
    with %URI{scheme: scheme, host: host, path: path} <- URI.parse(url),
         true <- scheme in ["http", "https"],
         true <- is_binary(host) and host != "" do
      case Map.get(body, "type", "pageview") do
        "pageview" ->
          {:ok,
           %{
             type: "pageview",
             hostname: String.downcase(host),
             path: normalize_path(path),
             referrer: Map.get(body, "referrer")
           }}

        type when type in ["custom_event", "event"] ->
          normalize_event(body, host)

        _other ->
          {:error, :invalid_hit}
      end
    else
      _ -> {:error, :invalid_hit}
    end
  end

  def normalize(_), do: {:error, :invalid_hit}

  defp normalize_event(%{"name" => name}, host)
       when is_binary(name) and byte_size(name) in 1..64 do
    if Regex.match?(~r/^[a-z0-9_-]+$/, name) do
      {:ok, %{type: "event", hostname: String.downcase(host), name: name}}
    else
      {:error, :invalid_hit}
    end
  end

  defp normalize_event(_body, _host), do: {:error, :invalid_hit}

  def deltas(nil, %{type: type}, now),
    do: deltas(%{last_at: now - @visit_ttl_ms - 1, pageviews: 0}, %{type: type}, now)

  def deltas(state, %{type: type}, now) do
    new_visit? = now - state.last_at > @visit_ttl_ms
    pageviews = if type == "pageview", do: 1, else: 0
    prior_pageviews = if new_visit?, do: 0, else: state.pageviews

    bounces =
      if pageviews == 1 and new_visit?,
        do: 1,
        else: if(pageviews == 1 and prior_pageviews == 1, do: -1, else: 0)

    {landing_page?, landing_page_recorded?} =
      landing_page_state(state, new_visit?, type)

    {%{
       pageviews: pageviews,
       # Daily visitor uniqueness is durable and assigned by Ingest's
       # `measure_visitor_seen` insert. ETS owns visit state only.
       visitors: 0,
       visits: if(new_visit?, do: 1, else: 0),
       landing_page_visits: if(landing_page?, do: 1, else: 0),
       bounces: bounces,
       duration_seconds: if(new_visit?, do: 0, else: max(div(now - state.last_at, 1_000), 0))
     },
     %{
       last_at: now,
       pageviews: prior_pageviews + pageviews,
       landing_page_recorded?: landing_page_recorded? or landing_page?
     }}
  end

  defp normalize_path(nil), do: "/"
  defp normalize_path("/"), do: "/"
  defp normalize_path(path), do: path |> String.trim_trailing("/") |> String.slice(0, 512)

  defp landing_page_state(state, new_visit?, type) do
    recorded? = if new_visit?, do: false, else: Map.get(state, :landing_page_recorded?, false)
    {type == "pageview" and not recorded?, recorded?}
  end
end
