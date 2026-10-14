defmodule AlplusWeb.WebsiteHealthCheckLive do
  @moduledoc """
  The free website health check at `/tools/website-health-check`, and the
  second marketing LiveView after the homepage (ARCHITECTURE.md §9).

  The check is one live HTTP request that is allowed ten seconds. A controller
  POST answered it with a new document, so the address a visitor had just
  typed left the screen, the wait showed nothing, and every rejection cost a
  full round trip. Here the same probe runs in `start_async/3`: the field
  keeps its value, the button carries the pending state, and the verdict lands
  in the column the form occupied.

  The dead render is the form, complete and indexable, and `mount/3` assigns
  the same `<head>` facts a controller page assigned, from
  `AlplusWeb.WebsiteHealthCheck.Page`.

  Two things stay with `AlplusWeb.WebsiteHealthCheckController`, because a
  LiveView owns no session: the draft that the monitor handoff reads, and the
  funnel journey id. Both travel as fields of the conversion form, which is a
  real POST rather than an event.
  """

  use AlplusWeb, :live_view

  import AlplusWeb.MarketingComponents
  import AlplusWeb.AuthComponents, only: [health_turnstile: 1]

  require Logger

  alias Alplus.Growth.HealthCheck
  alias Alplus.Monitoring.AnonymousProbe
  alias Alplus.Monitoring.AnonymousProbe.{Gate, RateLimiter}
  alias AlplusWeb.Marketing.Seo
  alias AlplusWeb.Plugs.CloudflareRemoteIp
  alias AlplusWeb.WebsiteHealthCheck.Page

  on_mount {AlplusWeb.LiveUserAuth, :current_user}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(Seo.seo_assigns(Page.seo_opts()))
     |> assign(:page_path, Page.path())
     |> assign(:breadcrumbs, Page.breadcrumbs())
     |> assign(:journey_id, HealthCheck.new_journey_id())
     |> assign(:client_ip, client_ip(socket))
     |> reset_check()}
  end

  @impl true
  def handle_event("check", params, socket) do
    turnstile_token = field(params, "turnstile_token")
    url = params |> field("target_url") |> String.trim()
    keyword = field(params, "keyword")
    socket = assign(socket, target_url: url, keyword: keyword)

    with :ok <- verify_turnstile(turnstile_token, socket.assigns.client_ip),
         {:ok, uri} <- AnonymousProbe.Url.parse(url),
         {:ok, parsed_keyword} <- AnonymousProbe.Url.keyword(blank_to_nil(keyword)),
         :ok <- RateLimiter.check(socket.assigns.client_ip),
         :ok <- Gate.admit(socket.assigns.journey_id) do
      display_url = AnonymousProbe.Url.display(uri)
      HealthCheck.record(socket.assigns.journey_id, "health_check_started")

      {:noreply,
       socket
       |> assign(state: :running, error: nil, result: nil, checked_url: display_url)
       |> start_async(:probe, fn -> AnonymousProbe.run(display_url, parsed_keyword) end)}
    else
      {:error, reason} ->
        {:noreply, assign(socket, state: :idle, error: rejection(reason), result: nil)}
    end
  end

  def handle_event("reset", _params, socket), do: {:noreply, reset_check(socket)}

  @impl true
  def handle_async(:probe, {:ok, {:ok, result}}, socket) do
    Gate.release(socket.assigns.journey_id)
    HealthCheck.record(socket.assigns.journey_id, "health_check_result_produced")

    {:noreply, assign(socket, state: :done, result: result, error: nil)}
  end

  # The probe only returns an error for an address it cannot parse, and this
  # LiveView parsed it before starting. Report it on the field rather than as
  # a result with no evidence in it.
  def handle_async(:probe, {:ok, {:error, reason}}, socket) do
    Gate.release(socket.assigns.journey_id)

    {:noreply, assign(socket, state: :idle, error: rejection(reason))}
  end

  def handle_async(:probe, {:exit, reason}, socket) do
    Gate.release(socket.assigns.journey_id)
    Logger.error("anonymous health check crashed: #{inspect(reason)}")

    {:noreply, assign(socket, state: :idle, error: :check_failed)}
  end

  defp reset_check(socket) do
    assign(socket,
      state: :idle,
      error: nil,
      result: nil,
      target_url: "",
      keyword: "",
      checked_url: nil
    )
  end

  defp field(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp verify_turnstile(token, remote_ip) do
    case Alplus.Turnstile.Client.verify(token, remote_ip) do
      {:ok, true} -> :ok
      _ -> {:error, :turnstile_failed}
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # `RateLimiter` answers with seconds and `Gate` with its own reasons; the
  # form speaks in outcomes.
  defp rejection(retry_after) when is_integer(retry_after), do: :rate_limited
  defp rejection(reason) when reason in [:busy, :journey_busy], do: :busy
  defp rejection(reason) when is_atom(reason), do: reason

  defp client_ip(socket) do
    if connected?(socket) do
      info = %{
        peer_data: get_connect_info(socket, :peer_data) || %{},
        x_headers: get_connect_info(socket, :x_headers) || []
      }

      CloudflareRemoteIp.connect_ip(info) || "unidentified"
    else
      "unidentified"
    end
  end

  @doc """
  What one anonymous probe reports, in the order the result shows it. Every
  row names a field `Alplus.Monitoring.AnonymousProbe` actually returns.
  """
  def check_returns do
    [
      %{
        term: "Final status",
        detail: "The HTTP status of the last response, and how long it took."
      },
      %{
        term: "Request path",
        detail: "Every redirect hop between your address and that response."
      },
      %{
        term: "Response headers",
        detail: "What served the page, the content type, the size read, and the cache rule."
      },
      %{
        term: "Security headers",
        detail: "Whether HSTS, CSP, X-Frame-Options, Referrer-Policy and nosniff are sent."
      },
      %{
        term: "DNS and certificate",
        detail:
          "The addresses the host resolved to, and, for HTTPS, certificate trust and days to expiry."
      },
      %{term: "Keyword", detail: "Whether your keyword appears in the HTML that came back."}
    ]
  end

  @doc """
  Which control a rejected check belongs to, so the message sits under the
  field that has to change. `:form` covers the states no field can fix.
  """
  def error_scope(reason) when reason in [:keyword_too_long, :invalid_keyword], do: :keyword

  def error_scope(reason) when reason in [:rate_limited, :busy, :check_failed, :turnstile_failed],
    do: :form

  def error_scope(_reason), do: :url

  def outcome_sentence(:ok), do: "The URL responded from PostDeploy's current region."
  def outcome_sentence(:timeout), do: "The request did not finish within 10 seconds."

  def outcome_sentence(:forbidden_address),
    do:
      "The host resolved to an address that is not on the public internet, so PostDeploy did not connect."

  def outcome_sentence(:dns_error), do: "PostDeploy could not resolve the host."

  def outcome_sentence(:too_many_redirects),
    do: "The URL redirected more than five times, so PostDeploy stopped."

  def outcome_sentence(:response_too_large),
    do: "The response was larger than 256 KB, so PostDeploy stopped reading."

  def outcome_sentence(:tls_untrusted),
    do: "The TLS certificate was not trusted, so PostDeploy did not fetch the page."

  def outcome_sentence(:network_error), do: "The request did not complete."
  def outcome_sentence(:forbidden_port), do: "The URL used a port that this check does not allow."
  def outcome_sentence(:forbidden_scheme), do: "Enter an http:// or https:// URL."
  def outcome_sentence(:userinfo), do: "Do not include usernames or passwords in the URL."
  def outcome_sentence(:fragment), do: "Do not include a #fragment in the URL."
  def outcome_sentence(:malformed_host), do: "Enter a public host name or address."
  def outcome_sentence(:invalid_url), do: "Enter a public domain or URL, for example example.com."
  def outcome_sentence(:url_too_long), do: "The URL is longer than 2,048 bytes."
  def outcome_sentence(:keyword_too_long), do: "The keyword is longer than 900 bytes."
  def outcome_sentence(:invalid_keyword), do: "Enter the keyword as plain text."
  def outcome_sentence(:rate_limited), do: "Too many checks right now. Try again in a moment."
  def outcome_sentence(:busy), do: "Too many checks are running. Try again in a moment."
  def outcome_sentence(:turnstile_failed), do: "Complete the security check and try again."
  def outcome_sentence(_), do: "The check did not complete."

  @doc """
  The result's answer: a status tone, the word beside the dot, and the
  sentence under it. A response carrying a 4xx or 5xx status is a reply, not a
  healthy site, so it never reads as the operational tone.
  """
  def verdict(%{outcome: :ok, final_status: status}) when is_integer(status) and status >= 400 do
    %{tone: :error, label: "Error status", sentence: "The URL responded with an error status."}
  end

  def verdict(%{outcome: :ok}) do
    %{tone: :live, label: "Responded", sentence: outcome_sentence(:ok)}
  end

  def verdict(%{outcome: :response_too_large = outcome}) do
    %{tone: :late, label: "Partly read", sentence: outcome_sentence(outcome)}
  end

  def verdict(%{outcome: outcome}) do
    %{tone: :error, label: verdict_label(outcome), sentence: outcome_sentence(outcome)}
  end

  defp verdict_label(:timeout), do: "Timed out"
  defp verdict_label(:dns_error), do: "DNS failed"
  defp verdict_label(:forbidden_address), do: "Address not public"
  defp verdict_label(:too_many_redirects), do: "Too many redirects"
  defp verdict_label(:tls_untrusted), do: "Certificate not trusted"
  defp verdict_label(:network_error), do: "No response"
  defp verdict_label(_outcome), do: "Check incomplete"

  def verdict_class(:live), do: "border-status-live-border bg-status-live-bg text-status-live-ink"
  def verdict_class(:late), do: "border-status-late-border bg-status-late-bg text-status-late-ink"

  def verdict_class(:error),
    do: "border-status-error-border bg-status-error-bg text-status-error-ink"

  def verdict_dot_class(:live), do: "bg-status-live"
  def verdict_dot_class(:late), do: "bg-status-late"
  def verdict_dot_class(:error), do: "bg-status-error"

  def status_value(nil), do: "None"
  def status_value(status), do: Integer.to_string(status)

  def tls_sentence(nil), do: "This was an HTTP request, so there is no certificate result."

  def tls_sentence(%{trusted: true, expires_at: %DateTime{} = expires_at}) do
    date = Calendar.strftime(expires_at, "%Y-%m-%d")

    case certificate_days(expires_at) do
      days when days > 1 -> "The certificate is trusted and expires in #{days} days, on #{date}."
      1 -> "The certificate is trusted and expires tomorrow, on #{date}."
      0 -> "The certificate is trusted and expires today."
      _ -> "The certificate expired on #{date}."
    end
  end

  def tls_sentence(%{trusted: true}), do: "The certificate is trusted. Expiry could not be read."
  def tls_sentence(%{trusted: false}), do: "The certificate is not trusted."

  @doc "Whole days from now until `expires_at`, negative once it has passed."
  def certificate_days(%DateTime{} = expires_at, now \\ DateTime.utc_now()),
    do: DateTime.diff(expires_at, now, :day)

  @doc "The certificate reading, or `nil` when the request carried no TLS."
  def certificate_reading(nil), do: nil
  def certificate_reading(%{trusted: false}), do: "Not trusted"

  def certificate_reading(%{trusted: true, expires_at: %DateTime{} = expires_at}) do
    case certificate_days(expires_at) do
      days when days > 1 -> "#{days} days"
      1 -> "1 day"
      0 -> "Today"
      _ -> "Expired"
    end
  end

  def certificate_reading(%{trusted: true}), do: "Trusted"

  @doc "How many redirects the probe followed."
  def redirect_count(%{hops: hops}), do: max(length(hops) - 1, 0)

  @doc """
  The security headers the check reports. `value` is `nil` when the server
  sent nothing.
  """
  def security_headers(%{headers: headers}) do
    [
      {"HSTS", "strict-transport-security"},
      {"Content Security Policy", "content-security-policy"},
      {"X-Frame-Options", "x-frame-options"},
      {"X-Content-Type-Options", "x-content-type-options"},
      {"Referrer-Policy", "referrer-policy"}
    ]
    |> Enum.map(fn {label, name} -> %{label: label, value: Map.get(headers, name)} end)
  end

  def response_header(%{headers: headers}, name), do: Map.get(headers, name)

  @doc "A byte count in the unit a reader thinks in."
  def format_bytes(bytes) when bytes < 1_024, do: "#{bytes} bytes"

  def format_bytes(bytes) when bytes < 1_024 * 1_024,
    do: "#{Float.round(bytes / 1_024, 1)} KB"

  def format_bytes(bytes), do: "#{Float.round(bytes / (1_024 * 1_024), 1)} MB"

  def keyword_sentence(nil), do: nil

  def keyword_sentence(%{value: value, matched: true}),
    do: "The response contained #{value}."

  def keyword_sentence(%{value: value, matched: false}),
    do: "The response did not contain #{value}."

  @doc "What the monitor button does next, which depends on having an account."
  def handoff_sentence(nil),
    do:
      "You create an account first, then PostDeploy creates the monitor and runs its first check."

  def handoff_sentence(_user),
    do: "PostDeploy asks you to confirm, then creates the monitor and runs its first check."
end
