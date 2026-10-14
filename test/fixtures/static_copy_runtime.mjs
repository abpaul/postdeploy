import vm from "node:vm";

const html = Buffer.from(process.argv[2], "base64").toString("utf8");
const script = html.match(/<script nonce=[^>]*>\s*\(\(\) => \{[\s\S]*?<\/script>/)?.[0]
  ?.replace(/^<script[^>]*>|<\/script>$/g, "");

if (!script) throw new Error("The static-page script was not rendered");

const listeners = new Map();
const copied = [];
const labels = [];
const targets = new Map();
const makeLabel = (text) => ({ textContent: text });
const makeButton = ({ target, label, liveView = false }) => ({
  dataset: { target },
  querySelector(selector) { return selector === "[data-copy-label]" ? label : null; },
  closest(selector) {
    if (selector === "button[data-copy-fallback][data-target]") return this;
    if (selector === "[data-phx-session]") return liveView ? {} : null;
    return null;
  },
});

const document = {
  documentElement: {
    hasAttribute() { return true; },
    setAttribute() {},
    removeAttribute() {},
  },
  body: { appendChild() {} },
  addEventListener(name, handler) { listeners.set(name, handler); },
  querySelectorAll() { return []; },
  getElementById(id) { return targets.get(id) || null; },
  createElement() {
    return {
      setAttribute() {}, style: {}, select() {}, remove() {}, value: "",
    };
  },
  execCommand() { return false; },
};
const context = {
  document,
  navigator: { clipboard: { writeText(text) { copied.push(text); return Promise.resolve(); } } },
  window: { addEventListener() {}, clearTimeout() {}, setTimeout() { return 1; } },
  localStorage: { getItem() { return null; }, removeItem() {}, setItem() {} },
  matchMedia() { return { matches: false, addEventListener() {} }; },
  Element: class Element {},
  requestAnimationFrame() {},
};
context.window.window = context.window;
vm.createContext(context);
vm.runInContext(script, context);

const click = listeners.get("click");
const copiedLabel = makeLabel("Copy");
targets.set("snippet", { innerText: "window.postdeployMeasure.push(['event', 'saved']);" });
await click({ target: makeButton({ target: "snippet", label: copiedLabel }) });

const missingLabel = makeLabel("Copy");
await click({ target: makeButton({ target: "missing", label: missingLabel }) });

const liveViewLabel = makeLabel("Copy");
await click({ target: makeButton({ target: "snippet", label: liveViewLabel, liveView: true }) });

context.navigator.clipboard.writeText = () => Promise.reject(new Error("denied"));
const failedLabel = makeLabel("Copy");
await click({ target: makeButton({ target: "snippet", label: failedLabel }) });

process.stdout.write(JSON.stringify({
  copied,
  copiedLabel: copiedLabel.textContent,
  missingLabel: missingLabel.textContent,
  liveViewLabel: liveViewLabel.textContent,
  failedLabel: failedLabel.textContent,
}));
