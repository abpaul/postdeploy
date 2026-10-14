defmodule Alplus.Analytics do
  @moduledoc """
  Product analytics (`docs/adr/0007-product-analytics.md`).

  Measure answers "how much traffic did the site get". Analytics answers
  "did the people who arrived finish onboarding, reach the core action, come
  back, and convert". The two never share a table: Measure stores aggregates
  and no identifier, while Analytics stores one row per event, carrying the
  opaque `distinct_id` the customer's own application supplies.

  The domain owns two configuration resources, `Funnel` and `Settings`.
  Events themselves have no Ash resource: ingest is a hot path and every
  read is a grouped aggregate, so both go through `Alplus.Analytics.Ingest`
  and `Alplus.Analytics.Queries` as documented direct SQL
  (`docs/DIRECT-ECTO-ESCAPE-HATCHES.md`).

  ## Privacy

  PostDeploy stores what the application sends and nothing else. It derives
  no identity from an IP address, sets no cookie, fingerprints no device,
  and never joins one project's events to another's.
  """

  use Ash.Domain, otp_app: :alplus

  resources do
    resource Alplus.Analytics.Funnel do
      define :create_funnel, action: :create
      define :update_funnel, action: :update
      define :destroy_funnel, action: :destroy
      define :get_funnel, action: :read, get_by: [:id]
      define :list_funnels_for_project, action: :list_for_project, args: [:project_id]
    end

    resource Alplus.Analytics.Settings do
      define :configure_settings, action: :upsert
      define :get_settings_for_project, action: :get_for_project, args: [:project_id]
    end
  end
end
