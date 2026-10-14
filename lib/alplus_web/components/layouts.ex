defmodule AlplusWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use AlplusWeb, :html

  alias AlplusWeb.Marketing.Seo

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  `:centered` (default) is the quiet wrapper for the public controller pages
  (status, changelog, Measure share) that render `data-public-shell` on
  their own content and supply their own nav and "Powered by PostDeploy"
  footer (mock 08) — no PostDeploy topbar or theme switcher stacks on top
  of the tenant's own identity here. `:bare` is the full-bleed slot the
  dashboard shell uses instead, since it supplies its own chrome entirely.

  Every current console page routes through `dashboard_shell/1`'s
  `variant={:bare}`, and every auth screen through `auth/1`/`auth_live/1`,
  so `:centered` never needs to carry console chrome — if a future
  non-public, non-dashboard page needs one, give it its own variant rather
  than reusing this one for the topbar it does not want either.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :variant, :atom,
    default: :centered,
    values: [:centered, :bare],
    doc:
      "`:centered` is the quiet centered wrapper public pages use around their own chrome; `:bare` is a full-bleed slot for the dashboard shell, which supplies its own chrome"

  slot :inner_block, required: true

  def app(%{variant: :bare} = assigns) do
    ~H"""
    {render_slot(@inner_block)}
    <.flash_group flash={@flash} />
    """
  end

  def app(assigns) do
    ~H"""
    <main class="px-4 py-10 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-wide">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  The full-bleed authentication shell (mock 06 "Auth + onboarding"). The
  mock draws its auth state inside a bordered, rounded, shadowed frame —
  that frame is the design-system document's device for presenting a
  screen specimen on a documentation page, not part of the screen itself.
  This shell strips it: a full-width top bar (brand lockup left, an
  optional quiet cross-link right) sits on a hairline bottom rule, and the
  body below it fills the rest of the viewport, centering the heading,
  supporting line, and a 380px-max-width form column both ways. Only the
  form column stays at a readable measure — the page chrome itself runs
  edge to edge, so this never reads as a card floating in an oversized
  viewport.

  `width` picks the body column's measure: `:form` (default) is the 380px
  form column; `:panel` widens to 640px for the one screen that presents a
  bordered decision panel rather than a field stack (OAuth consent).

  Used by every LiveView-owned signed-out screen (register, invitation,
  first org). The Ash-owned sign-in/reset/confirm routes use `auth_live/1`
  instead; both converge on the same full-bleed treatment so the two
  structures read as one authentication world.

  ## Examples

      <Layouts.auth flash={@flash} title="Create your account.">
        <:cross_link>
          Already have an account?
          <.link navigate={~p"/sign-in"}>Sign in</.link>
        </:cross_link>
        <:subtitle>You'll have a working workspace in a minute.</:subtitle>
        <.form for={@form}>...</.form>
      </Layouts.auth>
  """
  attr :flash, :map, required: true
  attr :title, :string, required: true

  attr :width, :atom,
    default: :form,
    values: [:form, :panel],
    doc: "body column measure: :form is the 380px field column, :panel is a 640px decision panel"

  slot :subtitle
  slot :cross_link, doc: "quiet header-row link, e.g. \"Already have an account? Sign in\""
  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <main data-public-shell class="flex min-h-dvh w-full flex-col bg-surface-raised">
      <div class="flex w-full flex-wrap items-center justify-between gap-3 border-b border-border-public px-5 py-4 sm:px-9 lg:px-16">
        <.logo variant={:full} size={:sm} href={~p"/"} class="w-fit" />
        <p :if={@cross_link != []} class="text-label text-text-secondary">
          {render_slot(@cross_link)}
        </p>
      </div>
      <div class="flex flex-1 flex-col items-center justify-center gap-3 px-5 py-12 text-center sm:px-9">
        <h1 class={
          if(@width == :panel,
            do: "text-heading-01 text-text-primary",
            else: "text-type-display text-text-primary"
          )
        }>
          {@title}
        </h1>
        <p :if={@subtitle != []} class="max-w-md text-body text-text-secondary">
          {render_slot(@subtitle)}
        </p>
        <div class={[
          "mt-5 w-full text-left",
          @width == :form && "max-w-[380px]",
          @width == :panel && "max-w-[640px]"
        ]}>
          {render_slot(@inner_block)}
        </div>
      </div>
    </main>
    <.flash_group flash={@flash} />
    """
  end

  @doc """
  LiveView layout for Ash-owned authentication routes: the same full-bleed
  shell as `auth/1` (mock 06), driven by plain assigns instead of slots
  because `AshAuthenticationPhoenix`'s route macros render this as a
  layout, not a caller-controlled component. `AlplusWeb.AuthPageTitle`'s
  `on_mount` hooks set `:heading`, `:page_subtitle`, and the
  `:cross_link_*` triplet per route; routes that don't assign them (reset,
  confirm) simply render without a header cross-link or supporting line.

  AshAuthenticationPhoenix's stock banner is intentionally disabled for these
  routes: it renders an unlabeled `img` and a heading-shaped `div`. Keeping the
  shell here gives every auth screen one real `h1` and one named home link while
  leaving the authentication components, strategies, and policies untouched.
  """
  def auth_live(assigns) do
    page_title = assigns[:page_title] || "PostDeploy"

    assigns =
      assigns
      |> assign_new(:flash, fn -> %{} end)
      |> assign(:page_title, page_title)
      |> assign_new(:heading, fn -> page_title end)
      |> assign_new(:page_subtitle, fn -> nil end)
      |> assign_new(:cross_link_lead, fn -> nil end)
      |> assign_new(:cross_link_label, fn -> nil end)
      |> assign_new(:cross_link_path, fn -> nil end)

    ~H"""
    <main
      id="auth-main"
      data-public-shell
      tabindex="-1"
      aria-labelledby="auth-page-title"
      class="flex min-h-dvh w-full flex-col bg-surface-raised"
    >
      <div class="flex w-full flex-wrap items-center justify-between gap-3 border-b border-border-public px-5 py-4 sm:px-9 lg:px-16">
        <.logo href={~p"/"} variant={:full} size={:sm} class="w-fit" />
        <p :if={@cross_link_label} class="text-label text-text-secondary">
          {@cross_link_lead}
          <.button variant="ghost" navigate={@cross_link_path}>{@cross_link_label}</.button>
        </p>
      </div>
      <div class="flex flex-1 flex-col items-center justify-center gap-3 px-5 py-12 text-center sm:px-9">
        <h1 id="auth-page-title" class="text-type-display text-text-primary">{@heading}</h1>
        <p :if={@page_subtitle} class="max-w-md text-body text-text-secondary">
          {@page_subtitle}
        </p>
        <div class="mt-5 w-full max-w-[380px] text-left">
          {@inner_content}
        </div>
      </div>
    </main>
    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <%!-- The lost-connection notice names what was detected, a dropped
            LiveView connection, and nothing it cannot prove. It never
            diagnoses the reader's network. After a bounded wait it offers the
            one recovery it can, a page reload, and says what that costs. --%>
      <.flash
        id="client-error"
        kind={:error}
        title={gettext("Connection to PostDeploy was lost")}
        phx-hook=".ConnectionLost"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        <span data-reconnecting>
          {gettext("Reconnecting…")}
          <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
        </span>
        <span data-reconnect-stalled hidden>
          {gettext("Still reconnecting. Unsaved changes may be lost.")}
          <button
            type="button"
            data-reload-page
            class="mt-2 inline-flex h-control-md items-center rounded-control border border-border-control bg-surface-raised px-3 text-label font-medium text-text-primary hover:bg-hover"
          >
            {gettext("Reload page")}
          </button>
        </span>
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Connection to PostDeploy was lost")}
        phx-hook=".ConnectionLost"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        <span data-reconnecting>
          {gettext("Reconnecting…")}
          <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
        </span>
        <span data-reconnect-stalled hidden>
          {gettext("Still reconnecting. Unsaved changes may be lost.")}
          <button
            type="button"
            data-reload-page
            class="mt-2 inline-flex h-control-md items-center rounded-control border border-border-control bg-surface-raised px-3 text-label font-medium text-text-primary hover:bg-hover"
          >
            {gettext("Reload page")}
          </button>
        </span>
      </.flash>
      <%!-- Reconnect success is announced here, without moving focus. --%>
      <p id="connection-status" role="status" class="sr-only"></p>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ConnectionLost">
        export default {
          mounted() {
            this.stalled = this.el.querySelector("[data-reconnect-stalled]")
            this.reconnecting = this.el.querySelector("[data-reconnecting]")
            this.observer = new MutationObserver(() => this.sync())
            this.observer.observe(this.el, {attributes: true, attributeFilter: ["hidden", "style", "class"]})
            this.el.querySelectorAll("[data-reload-page]").forEach(button => {
              button.addEventListener("click", () => window.location.reload())
            })
            this.sync()
          },
          visible() {
            return !this.el.hidden && this.el.style.display !== "none"
          },
          sync() {
            if (this.visible()) {
              if (!this.timer) {
                this.timer = setTimeout(() => {
                  this.reconnecting.hidden = true
                  this.stalled.hidden = false
                }, 15000)
              }
              window.__pdConnectionLost = true
            } else {
              clearTimeout(this.timer)
              this.timer = null
              this.reconnecting.hidden = false
              this.stalled.hidden = true
              // A reconnect re-mounts this hook, so the "was lost" fact lives
              // on window rather than on the hook instance.
              if (window.__pdConnectionLost) {
                // The reconnect re-renders the layout right after this runs,
                // so the announcement is written once that patch has settled.
                setTimeout(() => {
                  const status = document.getElementById("connection-status")
                  if (status) status.textContent = "Connected to PostDeploy again."
                }, 800)
              }
              window.__pdConnectionLost = false
            }
          },
          destroyed() {
            clearTimeout(this.timer)
            this.observer && this.observer.disconnect()
          }
        }
      </script>
    </div>
    """
  end

  attr :graphs, :list, default: []

  # encode_json_ld!/1 escapes closing script tags before this safe HTML boundary.
  # sobelow_skip ["XSS.Raw"]
  def json_ld_scripts(%{graphs: graphs}) do
    scripts =
      Enum.map(graphs, fn graph ->
        [
          "<script type=\"application/ld+json\">\n",
          Seo.encode_json_ld!(graph),
          "\n</script>\n"
        ]
      end)

    {:safe, scripts}
  end

  @doc """
  Our own Measure snippet, on our own marketing pages (dogfooding).

  Renders nothing unless `MEASURE_SELF_TOKEN` is configured, so a developer
  machine and CI never beacon into production analytics.

  Marketing pages only. Console URLs carry org and project public tokens in the
  path, and Measure persists the path, so instrumenting the console would file
  customer identifiers into our own analytics rollups for no analytical gain.

  The `src` is deliberately relative. `m.js` derives its ingest endpoint from
  its own `src`, so a relative path follows whichever host served the page,
  while an absolute `https://postdeploy.dev/m.js` would be a cross-origin script on
  any other hostname and blocked by our own CSP (`script-src 'self'`).
  """
  attr :marketing?, :boolean, default: false

  def measure_script(assigns) do
    assigns = assign(assigns, :token, Application.get_env(:alplus, :measure_self_token))

    ~H"""
    <script :if={@marketing? && is_binary(@token)} defer src={"/m.js?token=#{@token}"}>
    </script>
    """
  end
end
