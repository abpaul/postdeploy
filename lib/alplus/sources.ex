defmodule Alplus.Sources do
  @moduledoc """
  Unified telemetry Sources (`docs/adr/0001-unified-telemetry-sources.md`).

  A Source is a named, environment-scoped container for one product's
  (Monitor, Observe, Measure) data in one project. Each Source mints its
  own ingest credential on creation.

  Observe ingest authenticates a Source from its secret ingest key
  (`Alplus.Sources.Source.authenticate_observe/1`). Measure ingest resolves
  a Source from its public Measure token
  (`Alplus.Sources.Source.resolve_measure/1`) — the token is embedded in a
  served browser snippet, so unlike Observe it is not a possession-proves-
  authorization secret.
  """

  use Ash.Domain,
    otp_app: :alplus

  resources do
    resource Alplus.Sources.Source do
      define :create_source, action: :create
      define :get_source, action: :read, get_by: [:id]

      define :get_public_homepage_measure_source,
        action: :read_public_homepage_measure_source,
        args: [:source_id]

      define :list_public_homepage_measure_sources,
        action: :list_public_homepage_measure_sources

      define :list_sources, action: :read
      define :list_sources_for_project, action: :list_for_project, args: [:project_id]
      define :list_sources_for_projects, action: :list_for_projects, args: [:project_ids]
      define :rotate_source, action: :rotate, args: [:grace_period_seconds]
      define :rename_source, action: :rename
      define :configure_source_hostname, action: :configure_hostname
      define :revoke_source, action: :revoke
      define :destroy_source, action: :destroy
    end
  end
end
