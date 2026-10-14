defmodule AlplusWeb.MeasureScriptController do
  use AlplusWeb, :controller

  alias Alplus.Sources.Source

  # Split around the `site` assignment so a resolved Measure Source's
  # public token can be spliced in as a literal. The singleton stored on
  # `window.postdeployMeasure` owns dedupe state, queue draining, History wrappers,
  # and listener references across repeated script evaluation. `alplusMeasure`
  # remains an alias to the same object for existing snippets.
  #
  # `E` is absolute and derives from this script's origin. Customer pages post
  # back to PostDeploy, never to their own relative `/m`.
  @script_head "!function(){if(navigator.doNotTrack===\"1\"||window.doNotTrack===\"1\")return;var d=document,w=window,p=w.postdeployMeasure,l=w.alplusMeasure,t=p&&p.initialized?p:l&&l.initialized?l:null,C=d.currentScript,E=(C&&C.src?new URL(C.src).origin:location.origin)+\"/m\",site="
  @script_tail ";if(t){var o=t===p?l:p;if(Array.isArray(o)&&!o.__postdeployMeasureDrained){o.__postdeployMeasureDrained=1;for(var i=0;i<o.length;i++)t.push(o[i])}w.postdeployMeasure=t;w.alplusMeasure=t;return}var a=[];if(Array.isArray(p))a=a.concat(p);if(l!==p&&Array.isArray(l))a=a.concat(l);var s={initialized:1,last:\"\",endpoint:E,site:site,listeners:{},history:{}};w.postdeployMeasure=s;w.alplusMeasure=s;function send(type,name,force){type=type||\"pageview\";var k=location.href;if(type===\"pageview\"&&!force&&k===s.last)return;if(type===\"pageview\")s.last=k;var r=\"direct\";try{if(d.referrer)r=new URL(d.referrer).hostname||\"direct\"}catch(_){r=\"direct\"}var b=JSON.stringify({site:site,url:location.origin+location.pathname,referrer:r,type:type,name:name}),f=function(){try{var p=fetch(E,{method:\"POST\",mode:\"no-cors\",headers:{\"Content-Type\":\"text/plain\"},body:b,keepalive:true});if(p&&p.catch)p.catch(function(){})}catch(_){}};try{if(!(navigator.sendBeacon&&navigator.sendBeacon(E,new Blob([b],{type:\"text/plain\"}))))f()}catch(_){f()}}s.send=send;s.push=function(x){if(x)send(x[0],x[1])};for(var i=0;i<a.length;i++)s.push(a[i]);send();function nav(){send()}function show(e){if(e.persisted)send(null,null,true)}s.listeners.popstate=nav;s.listeners.hashchange=nav;s.listeners.pageshow=show;w.addEventListener(\"popstate\",nav);w.addEventListener(\"hashchange\",nav);w.addEventListener(\"pageshow\",show);var H=w.history;function wrap(n){var f=H[n];s.history[n]=f;H[n]=function(){var v=f.apply(this,arguments);send();return v}}wrap(\"pushState\");wrap(\"replaceState\")}();\n"

  # No `token` query param: legacy generic script, `site` still comes from
  # the browser's own `data-site` (or the `postdeployMeasure` queue).
  @generic_script @script_head <>
                    "C&&C.dataset&&C.dataset.site||p&&p.site||l&&l.site" <> @script_tail

  @doc """
  `GET /m.js` (no `token`): the legacy generic snippet.
  `GET /m.js?token=<measure_token>`: the token must resolve to an active
  `:measure` Source (`Alplus.Sources.Source.resolve_measure/1`); the
  served script embeds that Source's public token as a literal `site`
  value, instead of reading `data-site` from the caller's HTML.
  """
  def show(conn, %{"token" => token}) do
    case Source.resolve_measure(token) do
      {:ok, source} ->
        send_script(conn, @script_head <> Jason.encode!(source.measure_token) <> @script_tail)

      {:error, :not_found} ->
        send_resp(conn, 404, "")
    end
  end

  def show(conn, _params), do: send_script(conn, @generic_script)

  defp send_script(conn, body) do
    conn
    |> put_resp_content_type("application/javascript")
    |> put_resp_header("cache-control", "public, max-age=3600, stale-while-revalidate=86400")
    |> send_resp(200, body)
  end
end
