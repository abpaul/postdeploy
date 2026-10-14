defmodule Alplus.Projects do
  @moduledoc """
  Projects (ARCHITECTURE.md §3, §4). `AshArchival` soft-deletes with a
  14-day grace period; permanent purge is a future daily Oban job
  (ARCHITECTURE.md §13), not built in this slice.
  """

  use Ash.Domain,
    otp_app: :alplus

  resources do
    resource Alplus.Projects.Project do
      define :create_project, action: :create
      define :get_project, action: :read, get_by: [:id]
      define :list_projects, action: :read
      define :list_projects_for_org, action: :list_for_org, args: [:org_id]
      define :list_projects_for_orgs, action: :list_for_orgs, args: [:org_ids]
      define :update_project, action: :update
      define :archive_project, action: :archive
      define :activate_measure, action: :activate_measure
      define :activate_observe, action: :activate_observe
    end

    resource Alplus.Projects.ProjectDomain do
      define :create_project_domain, action: :create
      define :get_project_domain, action: :read, get_by: [:id]
      define :list_project_domains_for_project, action: :list_for_project, args: [:project_id]
      define :delete_project_domain, action: :destroy
    end
  end
end
