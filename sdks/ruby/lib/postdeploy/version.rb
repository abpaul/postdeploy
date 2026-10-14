# frozen_string_literal: true

module PostDeploy
  VERSION = "0.3.0"
  SDK_NAME = "postdeploy"

  # Sentinel default for `user:` on `Client#capture_exception`/
  # `#capture_message` — distinguishes "no per-call override given" (fall
  # back to the ambient `Scope` user) from an explicit `user: nil` (clear
  # the ambient user for this one capture), matching the JS SDK's
  # `overrides.user !== undefined` check in `scope.ts`'s `mergeScope`.
  UNSET = Object.new.freeze
end
