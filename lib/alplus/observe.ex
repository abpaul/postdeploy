defmodule Alplus.Observe do
  @moduledoc "Durable Observe grouping and release state."

  use Ash.Domain, otp_app: :alplus

  resources do
    resource Alplus.Observe.Issue do
      define :get_issue, action: :read, get_by: [:id]
      define :list_issues_for_project, action: :list_for_project, args: [:project_id]
      define :list_issues_for_projects, action: :list_for_projects, args: [:project_ids]
      define :list_public_issues_for_vendor, action: :list_public_for_vendor
      define :resolve_issue, action: :resolve
      define :ignore_issue, action: :ignore
      define :reopen_issue, action: :reopen
      define :destroy_issue, action: :destroy
      define :assign_issue, action: :assign
      define :merge_issue, action: :merge
      define :unmerge_issue, action: :unmerge
    end

    resource Alplus.Observe.IssueComment do
      define :list_issue_comments, action: :list_for_issue, args: [:issue_id]
      define :create_issue_comment, action: :create
      define :destroy_issue_comment, action: :destroy
      define :get_issue_comment, action: :read, get_by: [:id]
    end

    resource Alplus.Observe.IssueUserReport do
      define :list_issue_user_reports, action: :list_for_issue, args: [:issue_id]
      define :create_issue_user_report, action: :create
      define :destroy_issue_user_report, action: :destroy
      define :get_issue_user_report, action: :read, get_by: [:id]
    end

    resource Alplus.Observe.Release do
      define :get_release, action: :read, get_by: [:id]
      define :list_releases_for_project, action: :list_for_project, args: [:project_id]
      define :create_release, action: :create
    end

    resource Alplus.Observe.ReleaseArtifact do
      define :list_release_artifacts, action: :list_for_release, args: [:release_id]
      define :create_release_artifact, action: :create
    end

    resource Alplus.Observe.SessionRollup do
      define :list_session_rollups_for_release,
        action: :list_for_release,
        args: [:project_id, :environment, :release]
    end
  end
end
