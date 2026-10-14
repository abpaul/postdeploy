/**
 * Minimal ambient declaration for the one Node builtin this package's `/node`
 * adapter uses. Deliberately NOT `@types/node` as a devDependency: this
 * package's `tsconfig.json` sets `"types": []` precisely so `process`,
 * `Buffer`, and the rest of Node's ambient globals stay OUT of scope for
 * every other file (see `../core/observe/client.ts`'s `detectPlatform`
 * comment) -- pulling in all of `@types/node` here to get one class would
 * also pull in its global augmentations (and its own `setTimeout`/`fetch`
 * types, which conflict with this project's `lib: ["DOM"]` versions). A
 * narrow, hand-written declaration avoids both.
 */
declare module "node:async_hooks" {
  export class AsyncLocalStorage<T> {
    getStore(): T | undefined;
    run<R>(store: T, callback: () => R): R;
  }
}
