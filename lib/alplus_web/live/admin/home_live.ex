defmodule AlplusWeb.Admin.HomeLive do
  @moduledoc "Founder-only product, tenant, user, and usage detail."

  use AlplusWeb, :live_view

  require Logger

  import AlplusWeb.ConsoleComponents,
    only: [data_panel: 1, section_card: 1, stat_card: 1, status_badge: 1]

  alias Alplus.Growth.Funnel

  @views ~w(overview organizations users)
  @windows %{"7d" => 7, "30d" => 30, "90d" => 90}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Internal observability",
       summary: nil,
       dogfood_observe_path: nil,
       view: "overview",
       views: @views,
       window: "30d",
       windows: @windows,
       loading: true,
       load_error: nil
     )
     |> stream_configure(:organizations, dom_id: &"admin-org-#{&1.id}")
     |> stream_configure(:users, dom_id: &"admin-user-#{&1.id}")
     |> stream(:organizations, [])
     |> stream(:users, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    window = valid_param(params["window"], @windows, "30d")
    view = valid_param(params["view"], @views, "overview")
    now = DateTime.utc_now()
    since = DateTime.add(now, -Map.fetch!(@windows, window), :day)

    socket =
      socket
      |> assign(
        view: view,
        window: window,
        summary: nil,
        loading: true,
        load_error: nil
      )
      |> reset_active_stream(view)
      |> start_async({:admin_data, view}, fn -> admin_data(view, since, now) end)

    {:noreply, socket}
  end

  @impl true
  def handle_async({:admin_data, view}, {:ok, data}, %{assigns: %{view: view}} = socket) do
    {:noreply,
     socket
     |> assign(
       summary: data.summary,
       dogfood_observe_path: data.dogfood_observe_path,
       loading: false,
       load_error: nil
     )
     |> stream(:organizations, data.organizations, reset: true)
     |> stream(:users, data.users, reset: true)}
  end

  def handle_async({:admin_data, _view}, {:ok, _data}, socket), do: {:noreply, socket}

  def handle_async({:admin_data, view}, {:exit, reason}, %{assigns: %{view: view}} = socket) do
    Logger.error("Founder admin data load failed: #{inspect(reason)}")

    {:noreply,
     assign(socket,
       summary: nil,
       loading: false,
       load_error: "Product data could not be loaded. Reload this page."
     )}
  end

  def handle_async({:admin_data, _view}, {:exit, _reason}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-dvh bg-surface-page px-5 py-8 sm:px-8 lg:px-12">
      <div class="mx-auto max-w-wide">
        <header class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h1 class="text-type-display text-text-primary">Internal observability</h1>
            <p class="mt-2 max-w-measure text-body text-text-secondary">
              Inspect product adoption, tenant usage, and account state from persisted data.
            </p>
          </div>
          <nav aria-label="Internal tools" class="flex flex-wrap items-center gap-2">
            <.link
              href={~p"/admin/system"}
              class="inline-flex h-control-md items-center rounded-control border border-border-control px-3 text-label text-text-primary hover:bg-hover"
            >
              System metrics
            </.link>
            <.link
              :if={@dogfood_observe_path}
              href={@dogfood_observe_path}
              class="inline-flex h-control-md items-center rounded-control border border-border-control px-3 text-label text-text-primary hover:bg-hover"
            >
              Dogfood Observe
            </.link>
          </nav>
        </header>

        <nav aria-label="Admin sections" class="mt-8 flex gap-5 border-b border-border-default">
          <.link
            :for={view <- @views}
            patch={~p"/admin?view=#{view}&window=#{@window}"}
            class={[
              "border-b-2 px-0.5 pb-2.5 text-label font-medium capitalize",
              if(@view == view,
                do: "border-interactive-primary text-text-primary",
                else: "border-transparent text-text-secondary hover:text-text-primary"
              )
            ]}
            aria-current={@view == view && "page"}
          >
            {view}
          </.link>
        </nav>

        <div class="mt-5 flex flex-wrap items-center justify-between gap-3">
          <p class="text-caption text-text-secondary">
            Usage and activity in the last {@window}.
          </p>
          <div class="flex items-center gap-1 rounded-control border border-border-control bg-surface-raised p-1">
            <.link
              :for={window <- Map.keys(@windows) |> Enum.sort_by(&Map.fetch!(@windows, &1))}
              patch={~p"/admin?view=#{@view}&window=#{window}"}
              class={[
                "rounded-control-sm px-2.5 py-1.5 text-label",
                if(@window == window,
                  do: "bg-surface-inverse text-interactive-wash",
                  else: "text-text-secondary hover:bg-hover"
                )
              ]}
              aria-current={@window == window && "page"}
            >
              {window}
            </.link>
          </div>
        </div>

        <.data_panel
          :if={@loading}
          id="admin-loading"
          title="Loading product data"
          padded
          class="mt-5"
        >
          <p role="status" class="text-body text-text-secondary">Reading persisted product data.</p>
        </.data_panel>

        <.data_panel
          :if={@load_error}
          id="admin-load-error"
          title="Product data is unavailable"
          padded
          class="mt-5 border-status-error-border bg-status-error-bg"
        >
          <p role="alert" class="text-body text-status-error-ink">{@load_error}</p>
        </.data_panel>

        <section
          :if={@summary}
          aria-labelledby="product-health-title"
          class="mt-5"
        >
          <h2 id="product-health-title" class="sr-only">Product health</h2>
          <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <.stat_card
              id="admin-signups"
              label="Signups"
              value={@summary.signups}
              hint={"#{@summary.attributed_signups} attributed"}
            />
            <.stat_card
              id="admin-organizations"
              label="Organizations"
              value={@summary.organizations}
              hint="all organizations"
            />
            <.stat_card
              id="admin-configured"
              label="Configured"
              value={@summary.configured}
              hint="monitor, source, or domain"
            />
            <.stat_card
              id="admin-activated"
              label="Activated"
              value={@summary.activated}
              hint="received a real signal"
            />
            <.stat_card
              id="admin-monitors"
              label="Monitors"
              value={@summary.monitors}
              hint="created monitors"
            />
            <.stat_card
              id="admin-mcp-grants"
              label="MCP grants"
              value={@summary.mcp_grants}
              hint={"#{@summary.mcp_used} used"}
            />
          </div>
        </section>

        <div
          :if={@summary}
          class="mt-5 grid gap-5 lg:grid-cols-2"
        >
          <.section_card title="Activity" description="Organizations with a recent product signal.">
            <dl class="grid grid-cols-2 gap-4 sm:grid-cols-4">
              <.metric_row label="Active, 7 days" value={@summary.active_orgs.seven_days} />
              <.metric_row label="Active, 30 days" value={@summary.active_orgs.thirty_days} />
              <.metric_row label="MCP used" value={@summary.mcp_used} />
              <.metric_row label="Trial" value={@summary.billing.trial} />
              <.metric_row label="Subscribed" value={@summary.billing.subscribed} />
            </dl>
          </.section_card>

          <.section_card title="Sources" description="Configured sources by product type.">
            <dl class="grid grid-cols-2 gap-4 sm:grid-cols-4">
              <.metric_row label="Monitor" value={@summary.sources.monitor} />
              <.metric_row label="Observe" value={@summary.sources.observe} />
              <.metric_row label="Measure" value={@summary.sources.measure} />
              <.metric_row label="Changelog" value={@summary.sources.changelog} />
            </dl>
          </.section_card>
        </div>

        <.data_panel
          :if={@view == "organizations" and not @loading and is_nil(@load_error)}
          id="admin-organization-details"
          title="Organizations"
          description="Subscription, configuration, and real product usage for each tenant."
          class="mt-5"
        >
          <div id="admin-organizations-list" phx-update="stream" class="divide-y divide-border-subtle">
            <p
              id="admin-organizations-empty"
              class="hidden px-5 py-6 text-body text-text-secondary only:block"
            >
              No organizations exist.
            </p>
            <article
              :for={{dom_id, org} <- @streams.organizations}
              id={dom_id}
              class="px-5 py-4"
            >
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div class="min-w-0">
                  <h3 class="text-heading-03 text-text-primary">{org.name}</h3>
                  <p class="mt-1 break-all text-caption text-text-secondary">
                    {org.owner_email || "No owner"}<span aria-hidden="true">, </span>
                    <span class="font-mono">{org.public_token}</span>
                  </p>
                  <p class="mt-1 text-caption text-text-tertiary">
                    {source_summary(org.sources)}
                  </p>
                </div>
                <.status_badge
                  tone={billing_tone(org.billing_status)}
                  label={billing_label(org.billing_status)}
                />
              </div>
              <dl class="mt-4 grid grid-cols-2 gap-x-5 gap-y-3 sm:grid-cols-4 xl:grid-cols-8">
                <.detail_metric label="Members" value={org.members} />
                <.detail_metric label="Projects" value={org.projects} />
                <.detail_metric label="Monitors" value={org.monitors} />
                <.detail_metric label="Checks" value={org.usage.checks} />
                <.detail_metric label="Issues" value={org.usage.issues} />
                <.detail_metric label="Pageviews" value={org.usage.pageviews} />
                <.detail_metric label="MCP used" value={org.usage.mcp_used} />
                <div>
                  <dt class="text-label text-text-tertiary">Last signal</dt>
                  <dd class="mt-1 text-caption text-text-primary">
                    <.timestamp :if={org.usage.last_signal_at} at={org.usage.last_signal_at} />
                    <span :if={is_nil(org.usage.last_signal_at)}>None</span>
                  </dd>
                </div>
              </dl>
            </article>
          </div>
          <:footer>Up to 100 organizations, ordered by their latest signal in this window.</:footer>
        </.data_panel>

        <.data_panel
          :if={@view == "users" and not @loading and is_nil(@load_error)}
          id="admin-user-details"
          title="Users"
          description="Account confirmation, memberships, roles, and recorded product actions."
          class="mt-5"
        >
          <div id="admin-users-list" phx-update="stream" class="divide-y divide-border-subtle">
            <p
              id="admin-users-empty"
              class="hidden px-5 py-6 text-body text-text-secondary only:block"
            >
              No users exist.
            </p>
            <article :for={{dom_id, user} <- @streams.users} id={dom_id} class="px-5 py-4">
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div class="min-w-0">
                  <h3 class="break-all text-heading-03 text-text-primary">{user.email}</h3>
                  <p :if={user.name} class="mt-1 text-caption text-text-secondary">{user.name}</p>
                </div>
                <.status_badge
                  tone={if(user.confirmed_at, do: "success", else: "warning")}
                  label={if(user.confirmed_at, do: "Confirmed", else: "Unconfirmed")}
                />
              </div>
              <dl class="mt-4 grid grid-cols-2 gap-x-5 gap-y-3 sm:grid-cols-4">
                <.detail_metric label="Memberships" value={user.memberships} />
                <div>
                  <dt class="text-label text-text-tertiary">Roles</dt>
                  <dd class="mt-1 text-caption text-text-primary">{present(user.roles)}</dd>
                </div>
                <.detail_metric label="Actions" value={user.actions} />
                <div>
                  <dt class="text-label text-text-tertiary">Last action</dt>
                  <dd class="mt-1 text-caption text-text-primary">
                    <.timestamp :if={user.last_active_at} at={user.last_active_at} />
                    <span :if={is_nil(user.last_active_at)}>None</span>
                  </dd>
                </div>
              </dl>
              <p class="mt-3 text-caption text-text-secondary">
                Organizations: {present(user.organizations)}
              </p>
            </article>
          </div>
          <:footer>Up to 100 users, ordered by their latest recorded action in this window.</:footer>
        </.data_panel>
      </div>
    </main>
    """
  end

  defp reset_active_stream(socket, "organizations"),
    do: stream(socket, :organizations, [], reset: true)

  defp reset_active_stream(socket, "users"), do: stream(socket, :users, [], reset: true)
  defp reset_active_stream(socket, "overview"), do: socket

  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp detail_metric(assigns) do
    ~H"""
    <div>
      <dt class="text-label text-text-tertiary">{@label}</dt>
      <dd class="mt-1 text-data tabular-nums text-text-primary">{@value}</dd>
    </div>
    """
  end

  defp admin_data("overview", since, now) do
    %{
      summary: Funnel.admin_summary(since, now),
      organizations: [],
      users: [],
      dogfood_observe_path: Funnel.dogfood_observe_path()
    }
  end

  defp admin_data("organizations", since, _now) do
    %{
      summary: nil,
      organizations: Funnel.admin_organizations(since),
      users: [],
      dogfood_observe_path: Funnel.dogfood_observe_path()
    }
  end

  defp admin_data("users", since, _now) do
    %{
      summary: nil,
      organizations: [],
      users: Funnel.admin_users(since),
      dogfood_observe_path: Funnel.dogfood_observe_path()
    }
  end

  defp valid_param(value, allowed, fallback) when is_map(allowed) do
    if Map.has_key?(allowed, value), do: value, else: fallback
  end

  defp valid_param(value, allowed, fallback) when is_list(allowed) do
    if value in allowed, do: value, else: fallback
  end

  defp source_summary(sources) do
    [
      {sources.monitor, "Monitor"},
      {sources.observe, "Observe"},
      {sources.measure, "Measure"},
      {sources.changelog, "Changelog"}
    ]
    |> Enum.reject(fn {count, _label} -> count == 0 end)
    |> Enum.map_join(", ", fn {count, label} -> "#{count} #{label}" end)
    |> present("No sources")
  end

  defp billing_label("trialing"), do: "Trial"

  defp billing_label(billing_status),
    do: billing_status |> String.replace("_", " ") |> String.capitalize()

  defp billing_tone(status) when status in ["active", "trialing"], do: "success"
  defp billing_tone(status) when status in ["past_due", "incomplete"], do: "warning"
  defp billing_tone("canceled"), do: "error"
  defp billing_tone(_status), do: "neutral"

  defp present(value, fallback \\ "None")
  defp present("", fallback), do: fallback
  defp present(nil, fallback), do: fallback
  defp present(value, _fallback), do: value
end
