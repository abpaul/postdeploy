// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/alplus"
import topbar from "../vendor/topbar"
import {AuthTurnstile} from "./hooks/turnstile.mjs"

const LocalTime = {
  mounted() {
    localizeTimes(this.el)
  },
}

const FocusInvalid = {
  mounted() {
    this.focusInvalid()
  },

  updated() {
    this.focusInvalid()
  },

  focusInvalid() {
    const invalid = this.el.querySelector("[aria-invalid='true']")

    if (invalid && document.activeElement !== invalid) {
      invalid.focus()
    }
  },
}

const localizeTimes = (root = document) => {
  root.querySelectorAll("[data-local-time]").forEach(element => {
    const text = new Intl.DateTimeFormat(undefined, {
      month: "short",
      day: "numeric",
      hour: "numeric",
      minute: "2-digit",
    }).format(new Date(element.dateTime))
    element.textContent = text

    if (element.hasAttribute("data-local-time-title") && element.previousElementSibling) {
      element.previousElementSibling.title = `${text}: ${element.previousElementSibling.title}`
    }
  })
}

const StatusAutoRefresh = {
  mounted() {
    this.timer = startStatusAutoRefresh(this.el)
  },

  destroyed() {
    window.clearInterval(this.timer)
  },
}

const startStatusAutoRefresh = (element) => {
  if (element.__statusAutoRefreshTimer) return element.__statusAutoRefreshTimer

  const seconds = Number(element.dataset.refreshSeconds || 30)
  const timer = window.setInterval(() => {
    const active = document.activeElement
    const editing = active && active.matches("input, textarea, select, button, [contenteditable='true']")

    if (document.hidden || editing || (active && element.contains(active))) return
    refreshStatusContent(element)
  }, seconds * 1000)

  element.__statusAutoRefreshTimer = timer
  return timer
}

const refreshStatusContent = async (element) => {
  if (element.__statusRefreshPending) return
  element.__statusRefreshPending = true

  try {
    const response = await fetch(window.location.href, {
      headers: {Accept: "text/html", "X-Status-Refresh": "true"},
      credentials: "same-origin",
      cache: "no-store",
    })

    if (!response.ok) throw new Error(`Status refresh returned ${response.status}`)

    const documentFragment = new DOMParser().parseFromString(await response.text(), "text/html")
    const nextRoot = documentFragment.getElementById(element.id)
    if (!nextRoot) throw new Error(`Status refresh did not return #${element.id}`)

    const scrollX = window.scrollX
    const scrollY = window.scrollY
    element.replaceChildren(...nextRoot.childNodes)
    mountStatusTimezone(element)
    window.scrollTo(scrollX, scrollY)
  } catch (error) {
    console.warn("Status page refresh failed", error)
  } finally {
    element.__statusRefreshPending = false
  }
}

const StatusTimezone = {
  mounted() {
    mountStatusTimezone(this.el)
  },
}

const mountStatusTimezone = (root) => {
  const key = "alplus-status-timezone"
  const stored = window.localStorage.getItem(key)
  const mode = stored === "utc" ? "utc" : "local"
  const toggle = root.querySelector("[data-status-timezone-toggle]")

  const render = (selectedMode) => {
    const timeZone = selectedMode === "utc" ? "UTC" : undefined
    const options = {
      day: "2-digit",
      month: "short",
      year: "numeric",
      hour: "2-digit",
      minute: "2-digit",
      timeZoneName: "short",
      timeZone,
    }

    root.querySelectorAll("[data-status-time]").forEach(element => {
      const date = new Date(element.dataset.statusTime)
      if (Number.isNaN(date.getTime())) return
      element.textContent = new Intl.DateTimeFormat(undefined, options).format(date)
    })

    if (toggle) {
      toggle.textContent = selectedMode === "utc" ? "Use local time" : "Use UTC"
      toggle.setAttribute("aria-pressed", String(selectedMode === "utc"))
    }
  }

  render(mode)

  if (toggle && !toggle.__statusTimezoneBound) {
    toggle.addEventListener("click", () => {
      const nextMode = window.localStorage.getItem(key) === "utc" ? "local" : "utc"
      window.localStorage.setItem(key, nextMode)
      render(nextMode)
    })
    toggle.__statusTimezoneBound = true
  }
}

const touchTooltipForPoint = (point) => {
  const wrapper = point.parentElement
  return wrapper && wrapper.querySelector("[role='tooltip']")
}

const hideTouchTooltips = (except = null) => {
  document.querySelectorAll("[data-touch-visible='true']").forEach(tooltip => {
    if (except && tooltip === except) return

    tooltip.classList.add("hidden")
    tooltip.dataset.touchVisible = "false"
    tooltip.setAttribute("aria-hidden", "true")
  })
}

const showTouchTooltip = (point) => {
  const tooltip = touchTooltipForPoint(point)
  if (!tooltip) return

  hideTouchTooltips(tooltip)
  tooltip.classList.remove("hidden")
  tooltip.dataset.touchVisible = "true"
  tooltip.setAttribute("aria-hidden", "false")
}

const mountTouchTooltips = () => {
  if (document.__alplusTouchTooltipsMounted) return
  document.__alplusTouchTooltipsMounted = true

  document.addEventListener("click", event => {
    const point = event.target instanceof Element
      ? event.target.closest("[data-display-point][data-touch-tooltip]")
      : null

    if (point) {
      showTouchTooltip(point)
      return
    }

    if (!(event.target instanceof Element) || !event.target.closest("[data-touch-tooltip]")) {
      hideTouchTooltips()
    }
  })

  document.addEventListener("pointerdown", event => {
    if (!(event.target instanceof Element) || !event.target.closest("[data-touch-tooltip]")) {
      hideTouchTooltips()
    }
  })

  document.addEventListener("focusin", event => {
    const point = event.target instanceof Element
      ? event.target.closest("[data-display-point][data-touch-tooltip]")
      : null

    if (point) showTouchTooltip(point)
  })

  document.addEventListener("focusout", event => {
    const point = event.target instanceof Element
      ? event.target.closest("[data-display-point][data-touch-tooltip]")
      : null

    if (!point) return

    window.requestAnimationFrame(() => {
      if (!point.closest("[data-touch-tooltip]")?.contains(document.activeElement)) {
        hideTouchTooltips()
      }
    })
  })
}

const webMcpCancelledResult = () => ({
  ok: false,
  error: {code: "cancelled", message: "The operation was cancelled"},
})

const webMcpCancellation = (signal, error) =>
  signal?.aborted === true || error?.name === "AbortError"

const webMcpState = {
  mounted: false,
  key: null,
  names: new Set(),
  registrations: new Map(),
}

const webMcpSupported = () => {
  const context = document.modelContext
  return window.isSecureContext && context && (
    typeof context.registerTool === "function" ||
    typeof context.provideContext === "function"
  )
}

const webMcpUnregister = async () => {
  const context = document.modelContext
  if (!context) return

  for (const name of webMcpState.names) {
    try {
      if (typeof context.unregisterTool === "function") {
        await context.unregisterTool(name)
      }
    } catch (_) {
      // A stale browser registration must never break the dashboard.
    }
  }

  webMcpState.names.clear()
  webMcpState.registrations.clear()
  webMcpState.mounted = false
  webMcpState.key = null
}

const mountWebMcp = async () => {
  const root = document.querySelector("[data-webmcp-dashboard]")
  if (!root || !webMcpSupported()) return

  const orgId = root.dataset.webmcpOrgId
  const projectHandle = root.dataset.webmcpProjectHandle
  if (!orgId || !projectHandle) return
  const key = `${orgId}:${projectHandle}`
  if (webMcpState.mounted && webMcpState.key === key) return

  const query = new URLSearchParams({org_id: orgId, project_handle: projectHandle})
  let response
  try {
    response = await fetch(`/dashboard/webmcp/catalog?${query}`, {
      credentials: "same-origin",
      headers: {Accept: "application/json"},
      cache: "no-store",
    })
    if (!response.ok) return
    const catalog = await response.json()
    const context = document.modelContext
    await webMcpUnregister()

    const tools = (catalog.tools || []).map(tool => ({
      ...tool,
      execute: async (arguments_, {signal} = {}) => {
        if (webMcpCancellation(signal)) return webMcpCancelledResult()

        const args = {...(arguments_ || {})}
        if (tool.annotations?.readOnlyHint !== true && !args.idempotency_key) {
          args.idempotency_key = crypto.randomUUID()
        }

        const csrf = document.querySelector("meta[name='csrf-token']")?.content

        try {
          const result = await fetch("/dashboard/webmcp/call", {
            method: "POST",
            credentials: "same-origin",
            headers: {"content-type": "application/json", "x-csrf-token": csrf || ""},
            body: JSON.stringify({tool: tool.name, arguments: args, org_id: orgId, project_handle: projectHandle}),
            signal,
          })
          const payload = await result.json()
          if (!result.ok || payload.ok === false) {
            if (payload.error?.code === "cancelled") return webMcpCancelledResult()
            throw new Error(payload.error?.message || "WebMCP call failed")
          }
          return {data: payload.result, untrustedContent: true}
        } catch (error) {
          if (webMcpCancellation(signal, error)) return webMcpCancelledResult()
          throw error
        }
      },
    }))

    if (typeof context.provideContext === "function") {
      await context.provideContext({tools})
    } else {
      for (const tool of tools) {
        const registration = await context.registerTool(tool)
        webMcpState.registrations.set(tool.name, registration)
      }
    }

    webMcpState.names = new Set(tools.map(tool => tool.name))
    webMcpState.mounted = true
    webMcpState.key = key
  } catch (_) {
    await webMcpUnregister()
  }
}

document.addEventListener("DOMContentLoaded", () => {
  localizeTimes()
  document.querySelectorAll("[data-refresh-seconds]").forEach(startStatusAutoRefresh)
  document.querySelectorAll("[data-status-timezone-root]").forEach(mountStatusTimezone)
  mountTouchTooltips()
  mountWebMcp()
})

window.addEventListener("phx:page-loading-start", () => {
  webMcpUnregister()
})

window.addEventListener("phx:page-loading-stop", () => {
  mountWebMcp()
})

// After a live navigation the new screen's heading takes focus, so a keyboard
// or screen-reader user starts at the answer instead of at the logo. In-page
// patches (filters, ranges) keep the focus they had. Initial loads leave focus
// on the document, so the first Tab reaches the skip link.
const focusPageHeading = () => {
  const main = document.querySelector("main")
  const heading = (main && main.querySelector("h1")) || document.querySelector("main")
  if (!heading) return
  if (!heading.hasAttribute("tabindex")) heading.setAttribute("tabindex", "-1")
  heading.focus({preventScroll: false})
}

window.addEventListener("phx:navigate", info => {
  if (info.detail && info.detail.patch) return
  // The new view has joined, but its DOM lands a frame later.
  window.requestAnimationFrame(() => window.requestAnimationFrame(focusPageHeading))
})

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, LocalTime, FocusInvalid, AuthTurnstile, StatusAutoRefresh, StatusTimezone},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
