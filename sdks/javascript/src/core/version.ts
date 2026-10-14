/**
 * Single source of truth for the `header.sdk.name`/`header.sdk.version`
 * fields every Observe envelope carries. Keep `SDK_VERSION` in sync with
 * `package.json`'s `version` by hand -- there is no build step here that
 * injects it, and the alternative (reading `package.json` at runtime) would
 * require bundling JSON into every platform build for one string.
 */
export const SDK_NAME = "@postdeploy/sdk";
export const SDK_VERSION = "0.6.0";
