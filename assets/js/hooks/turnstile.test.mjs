import assert from "node:assert/strict"
import test from "node:test"

globalThis.window = {}
const {AuthTurnstile} = await import("./turnstile.mjs")

function browser({loaded = true, resetAfterSubmit = false} = {}) {
  const scripts = []
  const renders = []
  const removed = []
  const timers = []
  const listeners = new Map()
  const input = {value: "", dispatchEvent() {}}
  const error = {hidden: true, textContent: ""}
  const retry = {hidden: true, addEventListener(name, callback) {listeners.set(name, callback)}}
  const challenge = {replaceChildren() {}}
  const form = {
    addEventListener(name, callback) {listeners.set(name, callback)},
    removeEventListener(name) {listeners.delete(name)},
  }
  const vendor = {
    render(_element, options) {renders.push(options); return renders.length - 1},
    remove(id) {removed.push(id)},
  }
  globalThis.window = {setTimeout(callback) {timers.push(callback)}}
  if (loaded) window.turnstile = vendor
  globalThis.document = {
    getElementById() {return input},
    createElement() {return {remove() {this.parentNode = null}}},
    head: {appendChild(script) {script.parentNode = this; scripts.push(script)}},
  }
  const el = {
    dataset: {sitekey: "test-key", tokenId: "token", resetAfterSubmit: String(resetAfterSubmit)},
    closest() {return form},
    querySelector(selector) {
      return {"[data-turnstile-retry]": retry, "[data-turnstile-error]": error, "[data-turnstile-challenge]": challenge}[selector]
    },
  }
  const hook = Object.assign({el}, AuthTurnstile)
  return {hook, input, error, retry, scripts, renders, removed, vendor, timers, listeners}
}

async function settled() {
  await Promise.resolve()
  await Promise.resolve()
  await Promise.resolve()
}

test("a completed challenge fills the form token and expiry clears it", async () => {
  const b = browser()
  b.hook.mounted()
  await settled()
  assert.equal(b.renders.length, 1)
  b.renders[0].callback("valid-token")
  assert.equal(b.input.value, "valid-token")
  b.renders[0]["expired-callback"]()
  assert.equal(b.input.value, "")
  assert.equal(b.error.hidden, false)
  b.hook.destroyed()
  assert.deepEqual(b.removed, [0])
})

test("retry recovers from a failed script request", async () => {
  const b = browser({loaded: false})
  b.hook.mounted()
  b.scripts[0].onerror(new Error("network failure"))
  await settled()
  assert.equal(b.retry.hidden, false)
  b.listeners.get("click")()
  assert.equal(b.scripts.length, 2)
  window.turnstile = b.vendor
  b.scripts[1].onload()
  await settled()
  assert.equal(b.renders.length, 1)
  b.renders[0].callback("retry-token")
  assert.equal(b.input.value, "retry-token")
  assert.equal(b.error.hidden, true)
})

test("reset submission keeps the submitted token until serialization and creates a fresh challenge", async () => {
  const b = browser({resetAfterSubmit: true})
  b.hook.mounted()
  await settled()
  b.renders[0].callback("single-use-token")
  b.listeners.get("submit")()
  assert.equal(b.input.value, "single-use-token")
  b.timers[0]()
  await settled()
  assert.equal(b.input.value, "")
  assert.equal(b.renders.length, 2)
  b.renders[1].callback("next-token")
  assert.equal(b.input.value, "next-token")
  b.hook.destroyed()
  assert.equal(b.listeners.has("submit"), false)
})

test("destroyed hooks cannot render after pending script loading", async () => {
  const b = browser({loaded: false})
  b.hook.mounted()
  assert.equal(typeof b.hook.destroyed, "function")
  b.hook.destroyed()
  window.turnstile = b.vendor
  b.scripts[0].onload()
  await settled()
  assert.equal(b.renders.length, 0)
})

test("overlapping retries create only one live widget", async () => {
  const b = browser({loaded: false})
  b.hook.mounted()
  b.hook.mountWidget()
  b.hook.mountWidget()
  window.turnstile = b.vendor
  b.scripts[0].onload()
  await settled()
  assert.equal(b.renders.length, 1)
})
