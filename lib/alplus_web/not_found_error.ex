defmodule AlplusWeb.NotFoundError do
  @moduledoc """
  Raised from a LiveView `mount/3` to render a plain 404.

  ARCHITECTURE.md §4: a cross-tenant id (an org, project, or any other
  tenant-scoped id the actor cannot see) renders as 404, never 403 — the
  same response shape as an id that does not exist at all.
  """
  defexception message: "not found", plug_status: 404
end
