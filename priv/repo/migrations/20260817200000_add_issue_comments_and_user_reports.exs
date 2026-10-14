defmodule Alplus.Repo.Migrations.AddIssueCommentsAndUserReports do
  use Ecto.Migration

  @moduledoc """
  Comments and operator-recorded user reports on Observe issues.
  Both cascade when the issue is deleted.
  """

  def up do
    execute("SET lock_timeout = '3s'")

    execute("""
    CREATE TABLE issue_comments (
      id text PRIMARY KEY,
      org_id text NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
      project_id text NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      issue_id text NOT NULL REFERENCES issues(id) ON DELETE CASCADE,
      user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      body text NOT NULL,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT issue_comments_body_check CHECK (octet_length(btrim(body)) BETWEEN 1 AND 4096)
    )
    """)

    execute("""
    CREATE INDEX issue_comments_issue_inserted_at_index
      ON issue_comments (org_id, project_id, issue_id, inserted_at)
    """)

    execute("""
    CREATE TABLE issue_user_reports (
      id text PRIMARY KEY,
      org_id text NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
      project_id text NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      issue_id text NOT NULL REFERENCES issues(id) ON DELETE CASCADE,
      name text,
      email text,
      comments text NOT NULL,
      event_id text,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT issue_user_reports_name_check CHECK (name IS NULL OR octet_length(name) <= 256),
      CONSTRAINT issue_user_reports_email_check CHECK (email IS NULL OR octet_length(email) <= 256),
      CONSTRAINT issue_user_reports_comments_check CHECK (octet_length(btrim(comments)) BETWEEN 1 AND 4096),
      CONSTRAINT issue_user_reports_event_id_check CHECK (event_id IS NULL OR octet_length(event_id) <= 64)
    )
    """)

    execute("""
    CREATE INDEX issue_user_reports_issue_inserted_at_index
      ON issue_user_reports (org_id, project_id, issue_id, inserted_at)
    """)
  end

  def down do
    execute("DROP TABLE issue_user_reports")
    execute("DROP TABLE issue_comments")
  end
end
