export const turnstileLoader = () => {
  if (window.turnstile) return Promise.resolve()
  if (!window.__postdeployTurnstile) {
    window.__postdeployTurnstile = {promise: null, script: null}
  }
  const state = window.__postdeployTurnstile
  if (!state.promise) {
    const script = document.createElement("script")
    script.src = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit"
    script.async = true
    script.defer = true
    state.script = script
    state.promise = new Promise((resolve, reject) => {
      script.onload = resolve
      script.onerror = reject
      document.head.appendChild(script)
    }).catch(error => {
      if (state.script && state.script.parentNode) state.script.remove()
      state.script = null
      state.promise = null
      throw error
    })
  }
  return state.promise
}

window.PostDeployTurnstile = {load: turnstileLoader}

export const AuthTurnstile = {
  mounted() {
    this.generation = 0
    this.isDestroyed = false
    this.retryButton = this.el.querySelector("[data-turnstile-retry]")
    this.retryButton.addEventListener("click", () => this.mountWidget())
    this.form = this.el.closest("form")
    if (this.el.dataset.resetAfterSubmit === "true") {
      this.onSubmit = () => window.setTimeout(() => {
        if (!this.isDestroyed) this.reset()
      }, 0)
      this.form.addEventListener("submit", this.onSubmit)
    }
    this.mountWidget()
  },

  mountWidget() {
    const generation = ++this.generation
    this.clearWidget()
    this.clearToken()
    turnstileLoader()
      .then(() => {
        if (this.isDestroyed || generation !== this.generation) return
        const challenge = this.el.querySelector("[data-turnstile-challenge]")
        this.widgetId = window.turnstile.render(challenge, {
          sitekey: this.el.dataset.sitekey,
          size: "flexible",
          callback: token => {
            if (this.isDestroyed || generation !== this.generation) return
            const input = document.getElementById(this.el.dataset.tokenId)
            input.value = token
            input.dispatchEvent(new Event("input", {bubbles: true}))
            this.clearError()
          },
          "expired-callback": () => {
            this.clearToken()
            this.setError("Security check expired. Complete it again.")
          },
          "error-callback": () => {
            this.clearToken()
            this.setError("Security check could not load. Try again.", true)
          },
        })
      })
      .catch(() => {
        if (this.isDestroyed || generation !== this.generation) return
        this.clearToken()
        this.setError("Security check could not load. Try again.", true)
      })
  },

  clearToken() {
    const input = document.getElementById(this.el.dataset.tokenId)
    if (input) {
      input.value = ""
      input.dispatchEvent(new Event("input", {bubbles: true}))
    }
  },

  clearWidget() {
    if (this.widgetId != null && window.turnstile && window.turnstile.remove) {
      window.turnstile.remove(this.widgetId)
    }
    this.widgetId = null
    const challenge = this.el.querySelector("[data-turnstile-challenge]")
    if (challenge) challenge.replaceChildren()
  },

  reset() {
    this.clearToken()
    this.clearWidget()
    this.mountWidget()
  },

  destroyed() {
    this.isDestroyed = true
    if (this.onSubmit) this.form.removeEventListener("submit", this.onSubmit)
    this.generation += 1
    this.clearToken()
    this.clearWidget()
  },

  clearError() {
    this.el.querySelector("[data-turnstile-error]").hidden = true
    this.retryButton.hidden = true
  },

  setError(message, retryable = false) {
    const error = this.el.querySelector("[data-turnstile-error]")
    error.textContent = message
    error.hidden = false
    this.retryButton.hidden = !retryable
  },
}
