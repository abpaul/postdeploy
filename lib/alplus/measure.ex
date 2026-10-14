defmodule Alplus.Measure do
  @moduledoc "Measure configuration and durable analytics rollups."

  use Ash.Domain, otp_app: :alplus

  resources do
    resource Alplus.Measure.DashboardShare do
      define :get_dashboard_share, action: :read, get_by: [:id]
      define :get_dashboard_share_for_source, action: :for_source, args: [:source_id]
      define :create_dashboard_share, action: :create
      define :get_public_homepage_share, action: :public_homepage_for_vendor
      define :update_dashboard_share, action: :update_panels
      define :rotate_dashboard_share, action: :rotate
      define :revoke_dashboard_share, action: :revoke
    end

    resource Alplus.Measure.Goal do
      define :get_goal, action: :read, get_by: [:id]
      define :list_goals, action: :list_for_project, args: [:project_id]
      define :create_goal, action: :create
      define :update_goal, action: :update
      define :destroy_goal, action: :destroy
    end

    resource Alplus.Measure.CustomEventDefinition do
      define :get_event_definition, action: :read, get_by: [:id]
      define :list_event_definitions, action: :list_for_project, args: [:project_id]
      define :create_event_definition, action: :create
      define :destroy_event_definition, action: :destroy
    end

    resource Alplus.Measure.GoalConversion do
    end

    resource Alplus.Measure.AnalyticsHour do
      define :list_hours_for_project, action: :list_for_project, args: [:project_id]
      define :list_hours_for_source, action: :list_for_source, args: [:source_id, :since]

      define :list_hours_for_sources,
        action: :list_for_sources,
        args: [:source_ids, :since, :until]

      define :list_hours_for_share, action: :list_for_share, args: [:since, :until]

      define :list_public_homepage_hours,
        action: :public_homepage_for_vendor,
        args: [:source_ids, :since, :until]
    end

    resource Alplus.Measure.AnalyticsDay do
      define :list_days_for_project, action: :list_for_project, args: [:project_id]

      define :list_days_for_projects,
        action: :list_for_projects,
        args: [:project_ids, :source_ids, :since, :until]

      define :list_days_for_source, action: :list_for_source, args: [:source_id, :since]

      define :list_days_for_sources,
        action: :list_for_sources,
        args: [:source_ids, :since, :until]

      define :list_days_for_share, action: :list_for_share, args: [:since, :until]

      define :list_public_homepage_days,
        action: :public_homepage_for_vendor,
        args: [:source_ids, :since, :until]
    end

    resource Alplus.Measure.AnalyticsDimension do
      define :list_dimensions_for_project, action: :list_for_project, args: [:project_id]

      define :list_dimensions_for_source,
        action: :list_for_source,
        args: [:source_id, :since, :until, :environment]

      define :list_dimensions_for_share,
        action: :list_for_share,
        args: [:dimension, :since, :until]
    end
  end
end
