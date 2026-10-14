import vm from "node:vm";

const script = Buffer.from(process.argv[2], "base64").toString("utf8");

function runtime({ beaconAccepted, preloaded = [], legacyPreloaded = preloaded, initializedGlobal }) {
  let current = new URL("https://shop.example.test/start?private=1#top");
  const listeners = new Map();
  const requests = [];
  let beaconCalls = 0;
  let fetchCalls = 0;

  const location = {
    get href() { return current.href; },
    get origin() { return current.origin; },
    get pathname() { return current.pathname; },
  };
  const navigate = (url) => { current = new URL(url, current); };
  const history = {
    pushState(_state, _unused, url) { if (url !== undefined && url !== null) navigate(url); },
    replaceState(_state, _unused, url) { if (url !== undefined && url !== null) navigate(url); },
  };
  const addEventListener = (name, handler) => {
    const handlers = listeners.get(name) ?? [];
    handlers.push(handler);
    listeners.set(name, handlers);
  };
  const fire = (name, event = {}) => {
    for (const handler of listeners.get(name) ?? []) handler(event);
  };
  const queue = [...preloaded];
  const legacyQueue = legacyPreloaded === preloaded ? queue : [...legacyPreloaded];
  const trackerEvents = [];
  const initializedTracker = {
    initialized: 1,
    push(entry) { trackerEvents.push(entry); },
  };
  queue.site = "msr_fixture";
  legacyQueue.site = "msr_fixture";

  const context = {
    URL,
    Blob: class Blob {
      constructor(parts) { this.text = parts.join(""); }
    },
    document: {
      currentScript: { src: "https://ingest.postdeploy.dev/m.js" },
      referrer: "https://google.com/search?q=secret#private",
    },
    location,
    history,
    navigator: {
      doNotTrack: "0",
      sendBeacon(url, blob) {
        beaconCalls += 1;
        if (beaconAccepted) requests.push({ transport: "beacon", url, body: JSON.parse(blob.text) });
        return beaconAccepted;
      },
    },
    fetch(url, options) {
      fetchCalls += 1;
      requests.push({ transport: "fetch", url, body: JSON.parse(options.body) });
      return Promise.reject(new Error("fixture rejection"));
    },
    addEventListener,
    postdeployMeasure: initializedGlobal === "canonical" ? initializedTracker : queue,
    alplusMeasure: initializedGlobal === "legacy" ? initializedTracker : legacyQueue,
  };
  context.window = context;
  vm.createContext(context);

  return {
    evaluate() { vm.runInContext(script, context); },
    fire,
    navigate,
    history,
    context,
    requests,
    trackerEvents,
    counts() {
      return {
        beaconCalls,
        fetchCalls,
        listeners: Object.fromEntries([...listeners].map(([name, handlers]) => [name, handlers.length])),
      };
    },
  };
}

const unhandled = [];
const onUnhandled = (reason) => unhandled.push(String(reason));
process.on("unhandledRejection", onUnhandled);

const accepted = runtime({ beaconAccepted: true, preloaded: [["event", "preloaded"]] });
accepted.evaluate();
accepted.evaluate();
const tracker = accepted.context.postdeployMeasure;
const compatibilityTracker = accepted.context.alplusMeasure;
if (tracker !== compatibilityTracker) throw new Error("globals diverged");
accepted.context.postdeployMeasure.push(["event", "canonical"]);
accepted.context.alplusMeasure.push(["event", "compatibility"]);
accepted.evaluate();
accepted.history.pushState({}, "", "/next?campaign=secret#one");
accepted.history.pushState({}, "", "/next?campaign=secret#one");
accepted.history.replaceState({}, "", "/replaced#one");
accepted.navigate("/back");
accepted.fire("popstate");
accepted.fire("popstate");
accepted.navigate("/back#two");
accepted.fire("hashchange");
accepted.fire("hashchange");
accepted.fire("pageshow", { persisted: true });
accepted.fire("pageshow", { persisted: true });

const rejected = runtime({ beaconAccepted: false });
rejected.evaluate();
const separateQueues = runtime({
  beaconAccepted: true,
  preloaded: [["event", "canonical-preloaded"]],
  legacyPreloaded: [["event", "compatibility-preloaded"]],
});
separateQueues.evaluate();
separateQueues.evaluate();
const canonicalTracker = runtime({
  beaconAccepted: true,
  preloaded: [],
  legacyPreloaded: [["event", "legacy-queued"]],
  initializedGlobal: "canonical",
});
canonicalTracker.evaluate();
canonicalTracker.evaluate();
const legacyTracker = runtime({
  beaconAccepted: true,
  preloaded: [["event", "canonical-queued"]],
  legacyPreloaded: [],
  initializedGlobal: "legacy",
});
legacyTracker.evaluate();
legacyTracker.evaluate();
await Promise.resolve();
await Promise.resolve();
await new Promise((resolve) => setImmediate(resolve));
process.off("unhandledRejection", onUnhandled);

process.stdout.write(JSON.stringify({
  accepted: { counts: accepted.counts(), requests: accepted.requests },
  globals: {
    canonical: tracker === accepted.context.postdeployMeasure,
    compatibility: tracker === accepted.context.alplusMeasure,
  },
  separateQueues: { counts: separateQueues.counts(), requests: separateQueues.requests },
  canonicalTracker: {
    counts: canonicalTracker.counts(),
    aliases: canonicalTracker.context.postdeployMeasure === canonicalTracker.context.alplusMeasure,
    events: canonicalTracker.trackerEvents,
  },
  legacyTracker: {
    counts: legacyTracker.counts(),
    aliases: legacyTracker.context.postdeployMeasure === legacyTracker.context.alplusMeasure,
    events: legacyTracker.trackerEvents,
  },
  rejected: rejected.counts(),
  unhandled,
}));
