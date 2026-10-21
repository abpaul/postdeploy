(() => {
  const token = () => document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || "";

  window.postdeployFetch = (url, options = {}) => {
    const headers = new Headers(options.headers || {});
    const csrf = token();
    if (csrf && !headers.has("X-CSRF-Token")) headers.set("X-CSRF-Token", csrf);
    return fetch(url, { credentials: "same-origin", ...options, headers });
  };

  document.addEventListener("submit", (event) => {
    const form = event.target;
    if (!(form instanceof HTMLFormElement) || form.dataset.remote !== "true") return;
    event.preventDefault();
    const body = new FormData(form);
    window.postdeployFetch(form.action, { method: form.method || "post", body }).then((response) => {
      if (response.redirected) window.location.assign(response.url);
      else if (response.ok) window.location.reload();
      else {
        const status = form.querySelector("[data-remote-status]");
        if (status) status.textContent = "The request was not saved.";
      }
    });
  });

  document.querySelectorAll("[data-reveal-target]").forEach((button) => {
    button.addEventListener("click", () => {
      const panel = document.getElementById(button.dataset.revealTarget);
      if (!panel) return;
      const open = panel.classList.contains("hidden");
      panel.classList.toggle("hidden", !open);
      if (panel instanceof HTMLFormElement) panel.classList.toggle("flex", open);
      button.setAttribute("aria-expanded", String(open));
      if (open) panel.querySelector('input:not([type="hidden"])')?.focus();
    });
  });

  document.querySelectorAll("[data-reveal-close]").forEach((button) => {
    button.addEventListener("click", () => {
      const panel = button.closest("[data-reveal-panel]");
      if (!panel) return;
      panel.classList.add("hidden");
      if (panel instanceof HTMLFormElement) panel.classList.remove("flex");
      const control = [...document.querySelectorAll("[data-reveal-target]")]
        .find((candidate) => candidate.dataset.revealTarget === panel.id);
      control?.setAttribute("aria-expanded", "false");
      control?.focus();
    });
  });

  document.querySelectorAll("[data-confirm-match]").forEach((form) => {
    const input = form.querySelector('[name="confirmed_name"]');
    const submit = form.querySelector("[data-confirm-submit]");
    if (!input || !submit) return;
    const update = () => { submit.disabled = input.value !== form.dataset.confirmMatch; };
    input.addEventListener("input", update);
    update();
  });

  document.querySelectorAll("[data-close-details]").forEach((button) => {
    button.addEventListener("click", () => {
      const details = button.closest("details");
      if (!details) return;
      details.removeAttribute("open");
      details.querySelector("summary")?.focus();
    });
  });

  const openButton = document.getElementById("mobile-nav-open");
  const closeButton = document.getElementById("mobile-nav-close");
  const scrim = document.getElementById("mobile-nav-scrim");
  const drawer = document.getElementById("mobile-nav");

  const setDrawer = (open) => {
    if (!drawer || !openButton) return;
    drawer.classList.toggle("hidden", !open);
    drawer.style.display = open ? "block" : "";
    drawer.classList.toggle("-translate-x-full", !open);
    drawer.setAttribute("aria-hidden", open ? "false" : "true");
    openButton.setAttribute("aria-expanded", open ? "true" : "false");
    if (scrim) scrim.classList.toggle("hidden", !open);
    document.querySelector("[data-console-content]")?.toggleAttribute("inert", open);
    document.body.style.overflow = open ? "hidden" : "";
    if (open) closeButton?.focus();
    else openButton.focus();
  };

  openButton?.addEventListener("click", () => setDrawer(true));
  closeButton?.addEventListener("click", () => setDrawer(false));
  scrim?.addEventListener("click", () => setDrawer(false));
  window.addEventListener("keydown", (event) => {
    if (event.key === "Tab" && openButton?.getAttribute("aria-expanded") === "true") {
      const controls = [...drawer.querySelectorAll("a[href], button, input, select, [tabindex='0']")]
        .filter((node) => !node.disabled && node.getClientRects().length);
      const first = controls[0];
      const last = controls[controls.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last?.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first?.focus();
      }
    }
    if (event.key === "Escape" && openButton?.getAttribute("aria-expanded") === "true") {
      event.preventDefault();
      setDrawer(false);
    }
  });

  document.querySelectorAll("[data-menu]").forEach((menu) => {
    const button = document.querySelector(`[aria-controls="${menu.id}"]`);
    if (!button) return;
    const items = () => [...menu.querySelectorAll("[role='menuitem']")];
    const close = () => {
      menu.classList.add("hidden");
      menu.setAttribute("aria-hidden", "true");
      button.setAttribute("aria-expanded", "false");
    };
    const open = (index) => {
      menu.classList.remove("hidden");
      menu.setAttribute("aria-hidden", "false");
      button.setAttribute("aria-expanded", "true");
      const row = items()[index];
      if (row) row.focus();
    };
    button.addEventListener("click", () => {
      if (button.getAttribute("aria-expanded") === "true") close();
      else open(0);
    });
    button.addEventListener("keydown", (event) => {
      if (event.key === "ArrowDown") {
        event.preventDefault();
        open(0);
      } else if (event.key === "ArrowUp") {
        event.preventDefault();
        open(items().length - 1);
      }
    });
    menu.addEventListener("keydown", (event) => {
      const rows = items();
      const current = rows.indexOf(document.activeElement);
      if (event.key === "ArrowDown") {
        event.preventDefault();
        rows[(current + 1) % rows.length]?.focus();
      } else if (event.key === "ArrowUp") {
        event.preventDefault();
        rows[(current - 1 + rows.length) % rows.length]?.focus();
      } else if (event.key === "Escape") {
        event.preventDefault();
        close();
        button.focus();
      }
    });
    document.addEventListener("click", (event) => {
      if (!menu.contains(event.target) && event.target !== button) close();
    });
  });

  document.querySelectorAll("[data-copy-target]").forEach((button) => {
    button.addEventListener("click", async () => {
      const node = document.getElementById(button.getAttribute("data-copy-target") || "");
      const label = button.querySelector("[data-copy-label]");
      if (!node || !label) return;
      const text = node.innerText || "";
      const original = label.textContent;
      try {
        await navigator.clipboard.writeText(text);
        label.textContent = "Copied";
      } catch {
        label.textContent = "Copy failed";
      }
      window.setTimeout(() => {
        label.textContent = original;
      }, 2000);
    });
  });

  document.querySelectorAll("[data-flash-close]").forEach((button) => {
    button.addEventListener("click", () => {
      button.closest("[data-flash]")?.remove();
    });
  });

  const tail = document.querySelector("[data-log-tail]");
  const tailUrl = tail?.getAttribute("data-tail-url") || "";
  if (tail && tailUrl) {
    const list = tail.querySelector("[data-tail-list]");
    const status = tail.querySelector("[data-tail-status]");
    const stream = new EventSource(tailUrl, { withCredentials: true });
    window.addEventListener("pagehide", () => stream.close(), { once: true });
    const paint = (event) => {
      let row = null;
      try {
        row = JSON.parse(event.data);
      } catch {
        return;
      }
      if (!row) return;
      if (event.type === "gap" || row.kind === "gap") {
        if (status) {
          status.hidden = false;
          status.textContent = row.reason === "expired"
            ? "Some earlier lines have expired."
            : "This tail has a gap. Search the retained window to fill it.";
        }
        return;
      }
      if (!list) return;
      const item = document.createElement("li");
      item.className = "border-b border-border-subtle px-4 py-2 font-mono text-data text-text-primary";
      const at = row.at || (row.ts ? new Date(row.ts / 1000).toISOString() : "");
      const parts = [at, row.level, row.body ?? row.message].filter((part) => part);
      item.textContent = parts.join("  ");
      list.append(item);
      while (list.children.length > 500) list.firstElementChild.remove();
    };
    stream.addEventListener("log", paint);
    stream.addEventListener("entries", (event) => {
      let batch;
      try {
        batch = JSON.parse(event.data);
      } catch {
        return;
      }
      if (!Array.isArray(batch.rows)) return;
      for (const row of batch.rows.slice(0, 500)) {
        paint({ type: "log", data: JSON.stringify(row) });
      }
    });
    stream.addEventListener("gap", paint);
    stream.addEventListener("closing", () => {
      stream.close();
      if (status) {
        status.hidden = false;
        status.textContent = "The live tail stopped. Reload the page to connect again.";
      }
    });
    stream.onmessage = paint;
    stream.onerror = () => {
      if (!status) return;
      status.hidden = false;
      status.textContent = stream.readyState === EventSource.CLOSED
        ? "The live tail stopped. Reload the page to connect again."
        : "Reconnecting to the live tail…";
    };
    stream.onopen = () => {
      if (status && status.textContent === "Reconnecting to the live tail…") status.hidden = true;
    };
  }
  document.querySelectorAll("[data-arrival]").forEach((panel) => {
    const show = (selector, visible) => {
      const node = panel.querySelector(selector);
      if (node) node.hidden = !visible;
    };
    const render = (arrival) => {
      const errors = panel.querySelector("[data-arrival-errors]");
      const logs = panel.querySelector("[data-arrival-logs]");
      if (errors) errors.textContent = arrival.errors_received ? "Received" : "No error received yet";
      if (logs) logs.textContent = arrival.logs_received ? "Received" : "No log received yet";
      show("[data-arrival-errors-link]", arrival.errors_received);
      show("[data-arrival-logs-link]", arrival.logs_received);
      show("[data-arrival-waiting]", !arrival.errors_received);
      panel.querySelectorAll("[data-arrival-stopped]").forEach((node) => { node.hidden = true; });
      const received = arrival.errors_received || arrival.logs_received;
      const answer = document.querySelector("[data-arrival-answer]");
      if (answer && received) answer.textContent = "Events received";
      const agent = document.getElementById("source-agent");
      if (agent && received) agent.hidden = false;
    };
    const stop = (reason) => {
      show("[data-arrival-waiting]", false);
      panel.querySelectorAll("[data-arrival-stopped]").forEach((node) => { node.hidden = true; });
      show(`[data-arrival-stopped="${reason}"]`, true);
    };
    let checks = 0;
    let timer = null;
    const check = async () => {
      timer = null;
      checks += 1;
      try {
        const response = await fetch(panel.dataset.statusUrl, { credentials: "same-origin", headers: { Accept: "application/json" } });
        if (!response.ok) {
          stop("error");
          return;
        }
        const arrival = await response.json();
        render(arrival);
        if (arrival.errors_received) return;
      } catch {
        stop("error");
        return;
      }
      if (checks < 200) timer = setTimeout(check, 3000);
      else stop("timeout");
    };
    const checkSoon = () => {
      if (timer) clearTimeout(timer);
      timer = setTimeout(check, 500);
    };
    if (panel.dataset.errorsReceived !== "true") timer = setTimeout(check, 3000);

    const form = panel.querySelector("form[data-test-event]");
    const result = panel.querySelector("[data-test-event-result]");
    form?.addEventListener("submit", async (event) => {
      event.preventDefault();
      const button = form.querySelector('button[type="submit"]');
      if (button) button.disabled = true;
      try {
        const response = await fetch(form.action, {
          method: "POST",
          credentials: "same-origin",
          headers: { Accept: "application/json" },
          body: new URLSearchParams(new FormData(form)),
        });
        const answer = response.ok ? await response.json() : null;
        if (result) result.textContent = answer ? answer.message : "The test event was not sent. Reload the page and try again.";
        if (answer?.stored) checkSoon();
      } catch {
        if (result) result.textContent = "The test event was not sent. Check your connection and try again.";
      } finally {
        if (button) button.disabled = false;
      }
    });
  });
})();
