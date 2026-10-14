import type { WireStackFrame } from "./envelope";

/**
 * Best-effort `Error.stack` parser, V8 format only (`    at fn (file:line:col)`
 * / `    at file:line:col`). Covers Chrome, Node, and Cloudflare Workers
 * (workerd is V8), which is every platform this package ships an adapter
 * for -- Safari/Firefox's differently-shaped `.stack` strings are not
 * parsed and produce an empty frame list rather than a guess, since a wrong
 * frame is worse than no frames for grouping/display.
 *
 * `in_app` is left unset here (undefined, not `false`): this package has no
 * reliable way to know which frames belong to the caller's own code versus
 * a dependency, so it does not guess. The server treats an unset `in_app`
 * as computed server-side rather than trusted from the client.
 */
export function parseStack(stack: string | undefined): WireStackFrame[] {
  if (stack === undefined) return [];

  const frames: WireStackFrame[] = [];
  // The first line is `Error: message`, not a frame.
  for (const line of stack.split("\n").slice(1)) {
    const match = /^\s*at\s+(?:(.+?)\s+\()?(.+?):(\d+):(\d+)\)?\s*$/.exec(line);
    if (match === null) continue;
    const functionName = match[1];
    frames.push({
      ...(functionName !== undefined ? { function: functionName } : {}),
      file: match[2]!,
      lineno: Number(match[3]!),
      colno: Number(match[4]!),
    });
  }
  return frames;
}
