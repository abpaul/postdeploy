/**
 * Browser automatic breadcrumb instrumentation (docs/sdk/02-dx-improvements.md
 * section 3): navigation, delegated clicks, patched `console.*`, and patched
 * `fetch`. Every one of these wraps something ambient and MUST be reversible
 * on `close()` -- `unregisterAutoBreadcrumbs` undoes exactly what
 * `registerAutoBreadcrumbs` did, in reverse.
 *
 * `fetch` patching follows two rules from the spec verbatim: it wraps
 * whatever `globalThis.fetch` currently IS (not a reference captured once at
 * module load), so a caller who already patched `fetch` before `init()` is
 * composed with, not clobbered; and it only restores the original on
 * `close()` if `globalThis.fetch` is still exactly our wrapper (nobody
 * patched again on top of us since) -- unwinding a patch someone else
 * layered on top would silently break THEIR wrapper.
 *
 * Privacy: click breadcrumbs carry a CSS selector only, never element text
 * (AGENTS.md "no raw personal data without a bound" -- element text is
 * exactly the kind of incidental user input this rule exists to keep out of
 * a breadcrumb trail). Fetch/navigation URLs are stripped of their query
 * string by `../core/observe/breadcrumbs.ts`'s `stripQueryString` before
 * they ever reach the ring buffer.
 */
import { addBreadcrumb } from "./scope";
import { stripQueryString } from "../core/observe";
import { notifyLogBreadcrumb } from "../core/observe/client";
import { capText, MAX_BREADCRUMB_MESSAGE_CHARS } from "../core/observe/envelope";

type Cleanup = () => void;
const cleanups: Cleanup[] = [];

function safeAddBreadcrumb(input: Parameters<typeof addBreadcrumb>[0]): void {
  // A breadcrumb failure must never affect the instrumented call it came from.
  try {
    addBreadcrumb(input);
  } catch {
    // Swallowed deliberately: see file comment.
  }
}

/**
 * Guards every instrumentation source individually: a minimal/non-browser
 * `window` (as this package's own tests stub, or an unusual embedder) must
 * make `init()` skip what it can't safely instrument, never throw.
 */
function hasNavigationSupport(win: Window): win is Window & { location: Location; history: History } {
  return typeof win.location?.pathname === "string" && typeof win.history?.pushState === "function" && typeof win.history?.replaceState === "function" && typeof win.addEventListener === "function";
}

function registerNavigation(win: Window): void {
  if (!hasNavigationSupport(win)) return;
  const notify = (from: string, to: string) => safeAddBreadcrumb({ category: "navigation", message: `${from} -> ${to}`, level: "info" });
  let currentPath = `${win.location.pathname}${win.location.hash}`;

  const wrap = (method: "pushState" | "replaceState") => {
    const original = win.history[method].bind(win.history);
    win.history[method] = ((...args: Parameters<History["pushState"]>) => {
      const result = original(...args);
      const nextPath = `${win.location.pathname}${win.location.hash}`;
      notify(currentPath, nextPath);
      currentPath = nextPath;
      return result;
    }) as History["pushState"];
    cleanups.push(() => {
      win.history[method] = original;
    });
  };
  wrap("pushState");
  wrap("replaceState");

  const onPopState = () => {
    const nextPath = `${win.location.pathname}${win.location.hash}`;
    notify(currentPath, nextPath);
    currentPath = nextPath;
  };
  win.addEventListener("popstate", onPopState);
  cleanups.push(() => win.removeEventListener?.("popstate", onPopState));
}

/** Best-effort `tag#id.first-class` selector -- never element text content. */
function describeTarget(el: Element): string {
  const tag = el.tagName.toLowerCase();
  const id = el.id.length > 0 ? `#${el.id}` : "";
  const firstClass = typeof el.className === "string" && el.className.trim().length > 0 ? `.${el.className.trim().split(/\s+/)[0]}` : "";
  return `${tag}${id}${firstClass}`;
}

function registerClicks(doc: Document): void {
  if (typeof doc.addEventListener !== "function") return;
  const onClick = (event: MouseEvent) => {
    const target = event.target;
    if (!(target instanceof Element)) return;
    safeAddBreadcrumb({ category: "ui.click", message: describeTarget(target), level: "info" });
  };
  doc.addEventListener("click", onClick, { capture: true });
  cleanups.push(() => doc.removeEventListener?.("click", onClick, { capture: true }));
}

const CONSOLE_METHOD_LEVEL = { log: "info", info: "info", debug: "debug", warn: "warning", error: "error" } as const;

/**
 * The SDK's own diagnostics channel (`client.ts`'s `debugWarn`) prefixes
 * every line with this tag; those lines are the SDK talking to itself, not
 * the application's log narrative, so the console patch skips them
 * (issue #47's timeline must contain application output only).
 */
const SDK_INTERNAL_PREFIX = "[@postdeploy/sdk]";

function registerConsole(con: Console): void {
  (["log", "info", "debug", "warn", "error"] as const).forEach((method) => {
    if (typeof con[method] !== "function") return;
    const original = con[method].bind(con);
    con[method] = ((...args: unknown[]) => {
      const message = args.map((a) => (typeof a === "string" ? a : safeStringify(a))).join(" ");
      if (!message.startsWith(SDK_INTERNAL_PREFIX)) {
        safeAddBreadcrumb({ category: "console", message, level: CONSOLE_METHOD_LEVEL[method] });
        // Also offered to any exception item inside its post-error log
        // window (issue #47); a plain wire-shaped crumb, stamped here
        // because the scope ring stamps its own copy internally.
        try {
          notifyLogBreadcrumb({ category: "console", message: capText(message, MAX_BREADCRUMB_MESSAGE_CHARS), level: CONSOLE_METHOD_LEVEL[method], ts: new Date().toISOString() });
        } catch {
          // A pending-append failure must never affect the console call.
        }
      }
      return original(...args);
    }) as Console["log"];
    cleanups.push(() => {
      con[method] = original;
    });
  });
}

function safeStringify(value: unknown): string {
  try {
    return JSON.stringify(value) ?? String(value);
  } catch {
    return String(value);
  }
}

function registerFetch(target: typeof globalThis): void {
  if (typeof target.fetch !== "function") return;
  const patched: typeof fetch = async (input, init) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    const method = init?.method ?? (input instanceof Request ? input.method : "GET");
    const startedAt = Date.now();
    try {
      const response = await originalFetch(input, init);
      safeAddBreadcrumb({ category: "fetch", message: `${method} ${stripQueryString(url)}`, level: response.ok ? "info" : "warning", data: { status: response.status, duration_ms: Date.now() - startedAt } });
      return response;
    } catch (err) {
      safeAddBreadcrumb({ category: "fetch", message: `${method} ${stripQueryString(url)}`, level: "error", data: { duration_ms: Date.now() - startedAt } });
      throw err;
    }
  };
  const originalFetch = target.fetch.bind(target);
  target.fetch = patched;
  cleanups.push(() => {
    if (target.fetch === patched) target.fetch = originalFetch;
  });
}

export function registerAutoBreadcrumbs(): void {
  if (cleanups.length > 0) return;
  if (typeof window === "undefined") return;
  registerNavigation(window);
  if (typeof document !== "undefined") registerClicks(document);
  registerConsole(console);
  registerFetch(globalThis);
}

export function unregisterAutoBreadcrumbs(): void {
  while (cleanups.length > 0) cleanups.pop()!();
}
