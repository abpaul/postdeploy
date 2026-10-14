defmodule Alplus.Seo do
  @moduledoc "SEO visibility data presented inside Measure."

  use Ash.Domain, otp_app: :alplus

  resources do
    resource Alplus.Seo.Profile do
      define :get_profile, action: :read, get_by: [:id]
      define :get_profile_for_source, action: :for_source, args: [:source_id]
      define :list_profiles, action: :list_for_project, args: [:project_id]
      define :create_profile, action: :create
      define :update_profile, action: :update
    end

    resource Alplus.Seo.Competitor do
      define :list_competitors, action: :list_for_profile, args: [:profile_id]
      define :create_competitor, action: :create
      define :delete_competitor, action: :destroy
    end

    resource Alplus.Seo.Refresh do
      define :get_refresh, action: :read, get_by: [:id]
      define :queue_refresh, action: :queue
      define :start_refresh, action: :start
      define :succeed_refresh, action: :succeed
      define :fail_refresh, action: :fail
    end

    resource Alplus.Seo.Snapshot do
      define :latest_snapshot, action: :latest_for_profile, args: [:profile_id]
      define :create_snapshot, action: :create
    end
  end
end
