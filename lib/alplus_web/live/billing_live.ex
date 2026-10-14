defmodule AlplusWeb.BillingLive do
  @moduledoc """
  Billing state for one organization: the package, its trial or
  subscription state and renewal, the allowance ledger (every package limit,
  with this period's usage layered on where a usage number exists), and
  mirrored Stripe invoices.

  This LiveView reads the local Stripe mirror only. Checkout and Customer
  Portal are deliberately handled outside a LiveView request once the
  Stripe integration is configured.
  """

  use AlplusWeb, :live_view
  import AlplusWeb.DashboardComponents
  import AlplusWeb.OrgContext, only: [can_manage?: 1, owner?: 1]

  require Ash.Query

  alias Alplus.Billing.Package
  alias Alplus.Billing.StripeConfig
  alias Alplus.Billing.Usage
  alias AlplusWeb.Marketing.PackagePresenter

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"org_token" => org_token}, _session, socket) do
    with {:ok, socket} <-
           AlplusWeb.OrgContext.mount(org_token, socket, page_title: "Billing", active: :billing) do
      org_id = socket.assigns.org_id
      scope = socket.assigns.scope
      {:ok, stripe_environment} = StripeConfig.environment()

      subscription = mirrored_subscription(scope, org_id)

      billing_viewer? = can_manage?(scope)

      invoices =
        if billing_viewer? do
          Alplus.Billing.list_invoices!(stripe_environment, actor: scope)
        else
          []
        end

      # Subscription state and usage are organization facts. Every member may inspect them;
      # only invoice mirrors and Stripe actions stay behind the management
      # permission. `Usage` repeats the tenant scope at each read boundary.
      usage_meters = Usage.meters(scope, org_id)

      read_only? = read_only?(socket.assigns.org, subscription)

      {:ok,
       socket
       |> assign(:subscription, subscription)
       |> assign(:invoices, invoices)
       |> assign(:usage_meters, usage_meters)
       |> assign(:billing_owner?, owner?(scope))
       |> assign(:billing_viewer?, billing_viewer?)
       |> assign(:package, Package.get())
       |> assign(:trial_ends_at, socket.assigns.org.trial_ends_at)
       |> assign(:on_trial?, on_trial?(socket.assigns.org, subscription))
       |> assign(:billing_read_only?, read_only?)
       |> assign(:billing_purge_at, purge_at(socket.assigns.org, subscription))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_shell
      agent_connected?={@agent_connected?}
      flash={@flash}
      org={@org}
      organizations={@organizations}
      nav_projects={@nav_projects}
      scope={@scope}
      current_user={@current_user}
      active={:billing}
      page_title="Billing"
      page_heading?={false}
    >
      <.console_page id="billing-page">
        <:title>Billing</:title>
        <div :if={not connected?(@socket)} id="billing-loading" role="status">
          <.skeleton rows={4} />
        </div>

        <div :if={connected?(@socket)} class="flex flex-col gap-4">
          <%!-- No second breadcrumb inside the panel: the page header above
                already carries the org and page trail. The design source draws
                one there only because each screen is a specimen frame. --%>
          <.data_panel id="billing-summary" title="Subscription and usage">
            <div
              id="billing-state"
              data-billing-status={to_string(@org.billing_status)}
              data-read-only={to_string(@billing_read_only?)}
              class="grid divide-y divide-border-subtle sm:grid-cols-[1fr_1.4fr_1fr] sm:divide-x sm:divide-y-0"
            >
              <%!-- LEFT: package, price, status, renewal, and the owner's
                  actions in one column, mirroring the mock's package card. --%>
              <div class="min-w-0 space-y-4 p-4">
                <div id="billing-package">
                  <p class="text-ui font-semibold text-text-primary">
                    {@package.name}<span :if={@on_trial?}> trial</span>
                  </p>
                  <p id="billing-package-price" class="mt-1">
                    <span
                      :if={not @on_trial?}
                      class="text-metric-compact tabular-nums text-text-primary"
                    >
                      {PackagePresenter.price()}
                    </span>
                    <span class="text-data text-text-secondary">
                      {price_period(@on_trial?)}
                    </span>
                  </p>
                  <p class="mt-2 text-body text-text-secondary">
                    {package_pitch(@on_trial?)}
                  </p>
                  <ul
                    id="billing-included"
                    aria-label="Included in PostDeploy"
                    class="mt-3 space-y-1 text-body text-text-secondary"
                  >
                    <li :for={feature <- @package.features} id={"billing-included-#{feature.id}"}>
                      {feature.name}
                    </li>
                  </ul>
                  <p
                    :if={@billing_read_only?}
                    id="billing-read-only"
                    class="mt-3 text-body text-status-error-ink"
                  >
                    Read only. Billing must be restored before this organization can write new data.
                  </p>
                </div>

                <div id="billing-subscription-status" class="border-t border-border-subtle pt-4">
                  <p id="billing-status-badge">
                    <.status_badge
                      tone={billing_status_tone(@org, @subscription)}
                      label={billing_status_label(@org, @subscription)}
                    />
                  </p>
                  <p
                    :if={@subscription && @subscription.cancel_at_period_end}
                    id="billing-cancel-at-period-end"
                    class="mt-2 text-body text-status-late-ink"
                  >
                    Scheduled cancellation at the period end.
                  </p>
                  <p
                    :if={@subscription && @subscription.cancel_at_period_end}
                    id="billing-scheduled-cancellation"
                    class="mt-1 text-data text-text-secondary"
                  >
                    Ends <.timestamp at={@subscription.current_period_end} format={:date} />
                  </p>
                </div>

                <div id="billing-period-end" class="border-t border-border-subtle pt-4">
                  <p class="text-label font-medium text-text-tertiary">
                    {period_end_label(@on_trial?, @subscription)}
                  </p>
                  <p
                    :if={@on_trial? and @trial_ends_at}
                    id="billing-trial-end"
                    class="mt-1 text-heading-02 font-semibold tabular-nums text-text-primary"
                  >
                    <.timestamp at={@trial_ends_at} format={:date} />
                    <span class="text-data font-normal text-text-secondary">
                      ({trial_days_left(@trial_ends_at)} {trial_days_word(@trial_ends_at)} left)
                    </span>
                  </p>
                  <p
                    :if={@subscription}
                    id="billing-renewal"
                    class="mt-1 text-heading-02 font-semibold tabular-nums text-text-primary"
                  >
                    <.timestamp at={@subscription.current_period_end} format={:date} />
                  </p>
                  <p :if={@subscription} class="mt-1 text-data text-text-secondary">
                    {renewal_detail(@subscription)}
                  </p>
                  <p
                    :if={not @on_trial? and is_nil(@subscription)}
                    class="mt-1 text-body text-text-secondary"
                  >
                    No renewal date is mirrored.
                  </p>
                  <p
                    :if={@billing_read_only? and @billing_purge_at}
                    id="billing-purge-date"
                    class="mt-3 text-body text-status-error-ink"
                  >
                    Data purge date: <.timestamp at={@billing_purge_at} format={:date} />
                  </p>
                </div>

                <div
                  :if={@billing_owner?}
                  id="billing-owner-controls"
                  class="flex flex-wrap gap-2 border-t border-border-subtle pt-4"
                >
                  <%!-- Checkout only creates a subscription, so it appears only
                      without a live one. The event handler repeats the check. --%>
                  <.button
                    :if={not live_subscription?(@subscription)}
                    id="billing-subscribe"
                    variant="primary"
                    phx-click="checkout"
                    phx-disable-with="Opening checkout..."
                  >
                    Subscribe for {PackagePresenter.price()} a month
                  </.button>
                  <.button
                    :if={@subscription}
                    id="billing-manage-subscription"
                    variant="secondary"
                    phx-click="portal"
                    phx-disable-with="Opening billing portal..."
                  >
                    Manage subscription
                  </.button>
                </div>
              </div>

              <%!-- MIDDLE: usage and allowances, as label + mono value + pill
                  track rows instead of a wide table — every meter id, state,
                  and the dropped-events/legend copy is unchanged. --%>
              <div id="billing-allowance" class="min-w-0 space-y-4 p-4">
                <%!-- The one answer: am I inside my allowances. It is derived
                      from the same meter states the rows below print, and it
                      names the tightest meter rather than every meter. --%>
                <div>
                  <p class="text-label font-medium text-text-tertiary">Usage and allowances</p>
                  <p
                    id="billing-allowance-answer"
                    class={[
                      "mt-1 text-heading-02 font-semibold",
                      allowance_answer_class(@usage_meters)
                    ]}
                  >
                    {allowance_answer(@usage_meters)}
                  </p>
                </div>

                <div
                  :for={{id, meter} <- metered_rows(@usage_meters)}
                  id={id}
                  data-usage-state={meter_state(meter)}
                >
                  <div class="flex items-baseline justify-between gap-3 text-body">
                    <span class="text-text-primary">{meter.label}</span>
                    <span class={["font-mono text-data tabular-nums", meter_value_tone_class(meter)]}>
                      {meter_value_text(meter)}
                      <span class="sr-only">{meter_exact_value_text(meter)}</span>
                    </span>
                  </div>
                  <div
                    :if={meter_progress?(meter)}
                    role="progressbar"
                    aria-valuenow={meter.used}
                    aria-valuemin="0"
                    aria-valuemax={meter.limit}
                    aria-label={"#{meter.label} usage"}
                    class="mt-1.5 h-2 w-full overflow-hidden rounded-dot bg-surface-sunken"
                  >
                    <div
                      class={["h-full rounded-dot", meter_bar_tone_class(meter)]}
                      style={meter_bar_style(meter)}
                    />
                  </div>
                  <p :if={meter_state(meter) != :within_limit} class="mt-1.5">
                    <.status_badge tone={meter.tone} label={meter_state_label(meter)} />
                  </p>
                  <p
                    :if={meter.status == :dropped}
                    id={"#{id}-drops"}
                    class="mt-1.5 text-label text-status-error-ink"
                  >
                    Dropped events: {format_count(meter.dropped)}. New {String.downcase(meter.label)} are being dropped until the month resets.
                  </p>
                </div>

                <div
                  :for={row <- unmetered_rows()}
                  id={"usage-limit-#{row.key}"}
                  class="flex items-baseline justify-between gap-3 text-body"
                >
                  <span class="text-text-primary">{row.label}</span>
                  <span class="font-mono text-data tabular-nums text-text-primary">{row.value}</span>
                </div>

                <p
                  id="billing-allowance-legend"
                  class="border-t border-border-subtle pt-3 text-label text-text-tertiary"
                >
                  Warning at 80% of an allowance. At capacity at 100%. Monthly events are still accepted up to {PackagePresenter.event_ceiling_percent()} of the allowance, then dropped until the month resets.
                </p>
              </div>

              <%!-- RIGHT: invoice ledger, Geist Mono rows (date · amount ·
                  status), plus the billing-portal affordance for payment
                  method and full history. --%>
              <div id="billing-invoices" class="min-w-0 p-4">
                <p class="text-ui font-semibold text-text-primary">Invoices</p>

                <p :if={not @billing_viewer?} class="mt-3 text-body text-text-secondary">
                  Only billing managers can view invoices.
                </p>

                <div
                  :if={@billing_viewer? and @invoices == []}
                  id="billing-invoices-empty"
                  class="mt-3"
                >
                  <p class="text-body text-text-secondary">
                    <%= if @subscription && @billing_owner? do %>
                      No invoices yet. Open the billing portal to view the complete payment history.
                    <% else %>
                      No invoices yet. Invoices appear after the first payment.
                    <% end %>
                  </p>
                </div>

                <div
                  :if={@billing_viewer? and @invoices != []}
                  id="billing-invoices-table"
                  class="mt-3 divide-y divide-border-subtle"
                >
                  <div
                    :for={invoice <- @invoices}
                    id={"invoice-#{invoice.id}"}
                    class="flex items-center justify-between gap-3 py-2 font-mono text-data"
                  >
                    <a
                      :if={invoice.invoice_pdf_url}
                      href={invoice.invoice_pdf_url}
                      target="_blank"
                      rel="noopener noreferrer"
                      title={invoice.stripe_invoice_id}
                      class="min-w-0 truncate text-text-primary underline hover:text-interactive-strong-hover"
                    >
                      <.timestamp at={invoice.period_end} format={:date} />
                    </a>
                    <span
                      :if={is_nil(invoice.invoice_pdf_url)}
                      title={invoice.stripe_invoice_id}
                      class="min-w-0 truncate text-text-primary"
                    >
                      <.timestamp at={invoice.period_end} format={:date} />
                    </span>
                    <span class="tabular-nums text-text-primary">
                      {format_money(invoice_amount(invoice), invoice.currency)}
                    </span>
                    <span class={invoice_status_ink_class(invoice.status)}>
                      {invoice.status |> status_name() |> String.downcase()}
                    </span>
                  </div>
                </div>

                <p
                  :if={@billing_viewer? and @billing_owner? and @subscription}
                  class="mt-4 text-body text-text-secondary"
                >
                  Manage payment methods and the full invoice history in the billing portal.
                  <button
                    type="button"
                    id="billing-invoices-portal"
                    phx-click="portal"
                    phx-disable-with="Opening billing portal..."
                    class="min-h-target-min font-medium text-interactive-strong underline hover:text-interactive-strong-hover"
                  >
                    Open billing portal
                  </button>
                </p>
              </div>
            </div>
          </.data_panel>

          <p
            :if={not @billing_owner?}
            id="billing-owner-only-notice"
            class="text-body text-text-secondary"
          >
            Only the organization owner can manage billing.
          </p>
        </div>
      </.console_page>
    </.dashboard_shell>
    """
  end

  # -- Package & subscription -----------------------------------------------

  # The trial is the organization's state before any subscription exists. A
  # mirrored subscription always wins, whatever `billing_status` says.
  defp on_trial?(%{billing_status: :trialing}, nil), do: true
  defp on_trial?(_org, _subscription), do: false

  # A trial has no charge, so the amount is omitted. The amount and period
  # are split so the amount can carry the mock's large price weight.
  defp price_period(true), do: "no charge during the trial"
  defp price_period(false), do: "per month, plus tax"

  defp package_pitch(true) do
    "Every PostDeploy limit, free for #{Package.trial_days()} days with no card. " <>
      "When the trial ends, subscribe to keep writing data."
  end

  defp package_pitch(false),
    do: "One flat monthly price for this organization. No per-seat fees, no overage charges."

  defp invoice_status_ink_class(:paid), do: "text-status-live-ink"
  defp invoice_status_ink_class(status) when status in [:open, :void], do: "text-status-late-ink"
  defp invoice_status_ink_class(:uncollectible), do: "text-status-error-ink"
  defp invoice_status_ink_class(_status), do: "text-text-secondary"

  defp billing_status_label(org, subscription) do
    status = if subscription, do: subscription.status, else: org.billing_status

    case status do
      :trialing -> if read_only?(org, subscription), do: "Trial expired", else: "Trialing"
      :active -> "Active"
      :past_due -> "Past due"
      :canceled -> "Canceled"
      :incomplete -> "Incomplete"
      :incomplete_expired -> "Incomplete expired"
      :paused -> "Paused"
      :unpaid -> "Unpaid"
      _ -> "Billing unavailable"
    end
  end

  defp billing_status_tone(org, subscription) do
    status = if subscription, do: subscription.status, else: org.billing_status

    cond do
      status == :trialing and read_only?(org, subscription) -> "error"
      status in [:active] -> "success"
      status in [:past_due, :incomplete] -> "warning"
      status in [:canceled, :incomplete_expired, :unpaid] -> "error"
      true -> "neutral"
    end
  end

  defp read_only?(%{billing_status: :trialing, trial_ends_at: trial_ends_at}),
    do:
      is_nil(trial_ends_at) or
        DateTime.compare(to_datetime(trial_ends_at), DateTime.utc_now()) == :lt

  defp read_only?(%{billing_status: status}) when status in [:active, :past_due], do: false
  defp read_only?(_org), do: true

  defp read_only?(org, nil), do: read_only?(org)
  defp read_only?(_org, %{status: status}) when status not in [:active, :past_due], do: true
  defp read_only?(org, _subscription), do: read_only?(org)

  defp purge_at(org, subscription) do
    if read_only?(org, subscription) do
      anchor = if subscription, do: subscription.current_period_end, else: org.trial_ends_at
      if anchor, do: DateTime.add(to_datetime(anchor), Package.inactive_retention_days(), :day)
    end
  end

  defp to_datetime(%DateTime{} = value), do: value
  defp to_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

  defp renewal_detail(%{cancel_at_period_end: true}), do: "Scheduled cancellation"

  defp renewal_detail(%{status: status}) when status in [:active, :past_due],
    do: "Renews monthly"

  defp renewal_detail(_subscription), do: "Subscription ends"

  defp period_end_label(true, _subscription), do: "Trial deadline"
  defp period_end_label(false, %{cancel_at_period_end: true}), do: "Ends"
  defp period_end_label(false, _subscription), do: "Renewal"

  defp trial_days_left(ends_at) do
    remaining_seconds = max(DateTime.diff(ends_at, DateTime.utc_now()), 0)
    Integer.ceil_div(remaining_seconds, 86_400)
  end

  defp trial_days_word(ends_at) do
    if trial_days_left(ends_at) == 1, do: "day", else: "days"
  end

  defp status_name(status),
    do: status |> to_string() |> String.replace("_", " ") |> String.capitalize()

  # -- Allowance ledger -------------------------------------------------------
  #
  # One ledger shows every package limit exactly once, with usage layered on
  # where a usage number exists.
  #
  # The 5 metered rows mirror `Usage.meters/2`'s own fixed order and
  # labels. `cron_jobs` and `api_rate_limit_per_minute` have no usage meter
  # at all -- that is a fact about the product (nothing tracks per-org use
  # for them), not a gap to paper over.
  @metered_metrics [
    {:analytics_events, :analytics_events_per_month},
    {:error_events, :error_events_per_month},
    {:projects, :projects},
    {:members, :members},
    {:uptime_monitors, :uptime_monitors}
  ]

  @metered_labels %{
    analytics_events: "Analytics events",
    error_events: "Error events",
    projects: "Projects",
    members: "Team members",
    uptime_monitors: "Uptime monitors"
  }

  # `Usage.meters/3` runs for every member. It repeats the org scope for each
  # read, while invoices and external Stripe actions use the stronger manager
  # and owner checks above.
  defp metered_rows(usage_meters) do
    meters_by_metric = Map.new(usage_meters, &{&1.metric, &1})

    for {metric, limit_key} <- @metered_metrics do
      case Map.fetch(meters_by_metric, metric) do
        {:ok, meter} -> {"usage-meter-#{metric}", meter}
        :error -> {"usage-meter-#{metric}", unavailable_meter(metric, limit_key)}
      end
    end
  end

  # The tightest meter states the answer. `state` is the backend's own
  # threshold verdict (80% warning, capacity, dropped), never a ratio this
  # screen invents; a meter with no usage number cannot answer at all and
  # says so.
  defp allowance_answer(usage_meters) do
    meters = usage_meters |> metered_rows() |> Enum.map(&elem(&1, 1))

    case Enum.max_by(meters, &allowance_rank/1, fn -> nil end) do
      nil -> "No allowance data"
      %{status: :unavailable} -> "Some allowance readings are unavailable"
      %{state: :dropped} = meter -> "#{meter.label} over the ceiling, events dropping"
      %{state: :within_limit} -> "Inside every allowance"
      meter -> "#{meter.label} at #{allowance_percent(meter)} of allowance"
    end
  end

  defp allowance_percent(%{used: used, limit: limit})
       when is_integer(used) and is_integer(limit) and limit > 0,
       do: "#{round(used / limit * 100)}%"

  defp allowance_percent(_meter), do: "its limit"

  defp allowance_answer_class(usage_meters) do
    cond do
      Enum.any?(usage_meters, &(Map.get(&1, :tone) == "error")) -> "text-status-error-ink"
      Enum.any?(usage_meters, &(Map.get(&1, :tone) == "warning")) -> "text-status-late-ink"
      true -> "text-text-primary"
    end
  end

  defp allowance_rank(%{status: :unavailable}), do: 1
  defp allowance_rank(%{state: :dropped}), do: 4
  defp allowance_rank(%{state: :capacity}), do: 3
  defp allowance_rank(%{state: :warning}), do: 2
  defp allowance_rank(_meter), do: 0

  defp unavailable_meter(metric, limit_key) do
    %{
      metric: metric,
      label: @metered_labels[metric],
      used: nil,
      limit: Package.limit(limit_key),
      status: :unavailable,
      state: :unavailable,
      dropped: nil,
      tone: "warning"
    }
  end

  # These two are exact allowances rather than metered magnitudes, so they take
  # a thousands separator instead of `format_count/1`'s "1K" rounding: a
  # package that promises 1,000 cron jobs should say 1,000, not 1K.
  defp unmetered_rows do
    [
      %{
        key: :cron_jobs,
        label: "Cron and heartbeat jobs",
        value: PackagePresenter.thousands(Package.limit(:cron_jobs))
      },
      %{
        key: :min_check_interval_seconds,
        label: "Fastest check interval",
        value: PackagePresenter.interval_label(Package.limit(:min_check_interval_seconds))
      },
      %{
        key: :api_rate_limit_per_minute,
        label: "API rate limit",
        value: "#{PackagePresenter.thousands(Package.limit(:api_rate_limit_per_minute))}/min"
      }
    ]
  end

  defp format_count(n) when n >= 1_000_000, do: "#{div(n, 1_000_000)}M"
  defp format_count(n) when n >= 1_000, do: "#{div(n, 1_000)}K"
  defp format_count(n), do: to_string(n)

  defp meter_value_text(%{status: :unavailable, limit: limit}) when is_integer(limit),
    do: "Unavailable / #{format_count(limit)}"

  defp meter_value_text(%{status: :unavailable}), do: "Unavailable"

  defp meter_value_text(%{used: used, limit: limit}),
    do: "#{format_count(used)} / #{format_count(limit)}"

  defp meter_exact_value_text(%{status: :unavailable, limit: limit}) when is_integer(limit),
    do: "Usage unavailable, limit #{PackagePresenter.thousands(limit)}"

  defp meter_exact_value_text(%{status: :unavailable}), do: "Usage unavailable"

  defp meter_exact_value_text(%{used: used, limit: limit}),
    do: "#{PackagePresenter.thousands(used)} / #{PackagePresenter.thousands(limit)}"

  defp meter_value_tone_class(%{tone: "warning"}), do: "text-status-late-ink"
  defp meter_value_tone_class(%{tone: "error"}), do: "text-status-error-ink"
  defp meter_value_tone_class(_meter), do: "text-text-primary"

  defp meter_bar_tone_class(%{tone: "warning"}), do: "bg-status-late"
  defp meter_bar_tone_class(%{tone: "error"}), do: "bg-status-error"
  defp meter_bar_tone_class(_meter), do: "bg-interactive-primary"

  defp meter_progress?(%{status: status, used: used, limit: limit})
       when status != :unavailable and is_integer(used) and is_integer(limit),
       do: true

  defp meter_progress?(_meter), do: false

  defp meter_state(%{state: state}), do: state
  defp meter_state(%{status: status}), do: status

  defp meter_state_label(%{status: :unavailable}), do: "Unavailable"
  defp meter_state_label(%{state: :within_limit}), do: "Within limit"
  defp meter_state_label(%{state: :warning}), do: "Warning at 80%"
  defp meter_state_label(%{state: :capacity}), do: "At capacity"
  defp meter_state_label(%{state: :dropped}), do: "Events dropped"

  defp meter_bar_style(%{used: used, limit: limit}) do
    percent = used |> Kernel.*(100) |> Kernel./(limit) |> min(100) |> max(0)
    "width: #{Float.round(percent * 1.0, 1)}%"
  end

  # -- Invoices ---------------------------------------------------------------

  # A finalized-but-unpaid invoice (`:open`, `:draft`) has `amount_paid: 0`;
  # only a `:paid` invoice's paid amount reflects what was actually
  # collected, so every other status shows what is actually due.
  defp invoice_amount(%{status: :paid, amount_paid: amount_paid}), do: amount_paid
  defp invoice_amount(%{amount_due: amount_due}), do: amount_due

  defp format_money(cents, currency) do
    amount = :erlang.float_to_binary(cents / 100, decimals: 2)
    "#{amount} #{String.upcase(currency)}"
  end

  @impl true
  def handle_event("checkout", _params, socket) do
    case live_owner_scope(socket) do
      {:ok, live_scope} ->
        redirect_to_checkout(socket, live_scope)

      {:error, :billing_owner_required} ->
        {:noreply, put_flash(socket, :error, owner_required_message())}
    end
  end

  def handle_event("portal", _params, socket) do
    case live_owner_scope(socket) do
      {:ok, live_scope} ->
        case Alplus.Billing.Checkout.create_portal(live_scope, socket.assigns.org_id) do
          {:ok, url} -> {:noreply, redirect(socket, external: url)}
          {:error, reason} -> {:noreply, put_flash(socket, :error, billing_error(reason))}
        end

      {:error, :billing_owner_required} ->
        {:noreply, put_flash(socket, :error, owner_required_message())}
    end
  end

  # Every message this page can receive is incidental: the dev/test Stripe
  # double posts `{:stripe_checkout, params}` back to the calling process as its
  # assertion seam, and without a catch-all that message has no matching clause
  # and takes the LiveView down mid-checkout. Nothing here subscribes to a
  # topic, so there is no message this page is meant to act on.
  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  # Checkout itself refuses an organization that already pays, so a forged
  # event cannot buy a second subscription. That second subscription is the
  # 2026-09-10 incident.
  defp redirect_to_checkout(socket, scope) do
    case Alplus.Billing.Checkout.create_checkout(scope, socket.assigns.org_id) do
      {:ok, url} -> {:noreply, redirect(socket, external: url)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, billing_error(reason))}
    end
  end

  defp live_subscription?(%{status: status}) when status in [:active, :past_due], do: true
  defp live_subscription?(_subscription), do: false

  defp mirrored_subscription(scope, org_id) do
    {:ok, stripe_environment} = StripeConfig.environment()

    Alplus.Billing.list_subscriptions!(
      actor: scope,
      query:
        Ash.Query.filter(
          Alplus.Billing.Subscription,
          org_id == ^org_id and stripe_environment == ^stripe_environment
        )
    )
    |> List.first()
  end

  # The scope cached during mount is only a rendering convenience. Ownership
  # can change while this LiveView stays connected, so every event that can
  # reach Stripe or mutate billing state must rebuild the actor from the live
  # membership row first.
  defp live_owner_scope(socket) do
    with %Alplus.Scope{user_id: user_id} <- socket.assigns.scope,
         {:ok, live_scope} <-
           Alplus.Orgs.build_scope(
             Alplus.Scope.for_user(user_id),
             socket.assigns.org_id
           ),
         true <- owner?(live_scope) do
      {:ok, live_scope}
    else
      _ -> {:error, :billing_owner_required}
    end
  end

  defp billing_error(:billing_owner_required),
    do: "Only the organization owner can manage billing."

  defp billing_error(:stripe_customer_missing),
    do: "No Stripe customer exists for this organization yet."

  defp billing_error(:stripe_subscription_missing),
    do: "No active Stripe subscription exists for this organization yet."

  defp billing_error(:subscription_already_active),
    do: "This organization already has a subscription. Manage it in the billing portal."

  defp billing_error(:stripe_price_not_configured), do: "Billing is not configured yet."
  defp billing_error(_), do: "Billing could not start. Try again."

  defp owner_required_message, do: billing_error(:billing_owner_required)
end
