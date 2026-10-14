# Dialyzer findings that come from a dependency's own code (not ours) and
# would be wiped out on `deps.get` if fixed there. Each entry names the file
# and warning text so a real new finding elsewhere still fails the build.
[
  # ash_authentication_phoenix (2.x) references `Ash.Resource.record/0`, a
  # type that the currently pinned `ash` (3.x) no longer exports under that
  # name. A version-skew issue between two deps, not app code.
  {"lib/ash_authentication_phoenix/controller.ex", "Unknown type: Ash.Resource.record/0."}
]
