defmodule Alplus.Observe.IssueEvidence do
  @moduledoc """
  Read-side evidence for one Observe issue page.

  `page/2` and `discussion_page/4` are the external seams: `page/2` returns
  occurrences, users affected, and the merge group; `discussion_page/4`
  returns one page of comments or user reports. `recent/2`, `fetch/3`, and
  `users_affected/2` stay as internal seams for tests that do not need the
  full page.

  The hot ingest path (`EventWriter`) never uses this module — it is a
  read-only companion, kept out of the write transaction on purpose.
  """

  alias Alplus.Observe.{Issue, IssueComment, IssueUserReport, Occurrence}
  alias Alplus.Repo

  require Ash.Query

  @recent_limit 20
  @merged_children_page_size 20
  @discussion_page_size 20

  @columns ~w(event_id received_at occurred_at level message exception_type
              exception_value frames context tags breadcrumbs release sdk_name
              sdk_version payload_s3_key user_id user_email mechanism causes)a

  @select_sql """
  SELECT event_id, received_at, occurred_at, level, message, exception_type,
         exception_value, frames, context, tags, breadcrumbs, release, sdk_name,
         sdk_version, payload_s3_key, user_id, user_email, mechanism, causes
  FROM error_events
  """

  @type page :: %{
          occurrences: [Occurrence.t()],
          users_affected: non_neg_integer(),
          merged_children: [Issue.t()],
          merged_children_count: non_neg_integer(),
          merged_children_more?: boolean(),
          merged_children_next_page: pos_integer() | nil,
          merged_parent: Issue.t() | nil,
          group_event_count: non_neg_integer()
        }

  @doc """
  Loads everything the issue page needs except org members.

  Tenant-scoped: `scope` must already carry both `org_id` and `project_id`.
  Merged children aggregate by reference, not by moving rows.
  """
  @spec page(Alplus.Scope.t(), Issue.t()) :: page()
  def page(%{org_id: org_id, project_id: project_id} = scope, %Issue{} = issue)
      when is_binary(org_id) and is_binary(project_id) do
    children_page = merged_children_page(scope, issue.id)
    children = children_page.results

    %{
      occurrences: recent_for_group(scope, issue.id),
      users_affected: users_affected_for_group(scope, issue.id),
      merged_children: children,
      merged_children_count: merged_children_count(scope, issue.id),
      merged_children_more?: children_page.more?,
      merged_children_next_page: children_page.next_page,
      merged_parent: merged_parent(scope, issue),
      group_event_count: issue.event_count + merged_children_event_count(scope, issue.id)
    }
  end

  @doc "The number of comments or user reports on one discussion page."
  @spec discussion_page_size() :: pos_integer()
  def discussion_page_size, do: @discussion_page_size

  @doc """
  Returns one page of an issue's discussion as `{rows, total, more?}`.

  `kind` is `:comments` (oldest first, author loaded) or `:reports`
  (newest first). `total` counts every row, not only this page.
  """
  @spec discussion_page(Alplus.Scope.t(), String.t(), :comments | :reports, pos_integer()) ::
          {[struct()], non_neg_integer(), boolean()}
  def discussion_page(scope, issue_id, kind, page)
      when kind in [:comments, :reports] and is_binary(issue_id) do
    query = discussion_query(scope, issue_id, kind)
    rows = discussion_rows(query, scope, kind, page)

    {Enum.take(rows, @discussion_page_size), Ash.count!(query, actor: scope),
     length(rows) > @discussion_page_size}
  end

  defp discussion_query(scope, issue_id, :comments) do
    IssueComment
    |> Ash.Query.for_read(:list_for_issue, %{issue_id: issue_id}, actor: scope)
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
  end

  defp discussion_query(scope, issue_id, :reports) do
    IssueUserReport
    |> Ash.Query.for_read(:list_for_issue, %{issue_id: issue_id}, actor: scope)
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
  end

  defp discussion_rows(query, scope, kind, page) do
    query
    |> Ash.Query.limit(@discussion_page_size + 1)
    |> Ash.Query.offset((page - 1) * @discussion_page_size)
    |> then(fn q -> if kind == :comments, do: Ash.Query.load(q, :author), else: q end)
    |> Ash.read!(actor: scope)
  end

  @doc "Returns one bounded page of merged children under the issue scope."
  @spec merged_children(Alplus.Scope.t(), String.t()) :: [Issue.t()]
  def merged_children(scope, issue_id), do: merged_children_page(scope, issue_id).results

  @doc "Returns a bounded continuation page of merged children."
  @spec merged_children_page(Alplus.Scope.t(), String.t(), pos_integer()) :: map()
  def merged_children_page(scope, issue_id, page \\ 1) do
    page = normalize_page(page)

    rows =
      scope
      |> merged_children_query(issue_id)
      |> Ash.Query.sort(last_seen_at: :desc, id: :desc)
      |> Ash.Query.limit(@merged_children_page_size + 1)
      |> Ash.Query.offset((page - 1) * @merged_children_page_size)
      |> Ash.read!(actor: scope)

    results = Enum.take(rows, @merged_children_page_size)

    %{
      results: results,
      more?: length(rows) > @merged_children_page_size,
      next_page: if(length(rows) > @merged_children_page_size, do: page + 1)
    }
  end

  @doc "Counts all merged children without loading them into the page."
  @spec merged_children_count(Alplus.Scope.t(), String.t()) :: non_neg_integer()
  def merged_children_count(scope, issue_id),
    do: Ash.count!(merged_children_query(scope, issue_id), actor: scope)

  defp recent_for_group(%{org_id: org_id, project_id: project_id}, issue_id) do
    %{rows: rows} =
      Repo.query!(
        @select_sql <>
          """
          WHERE org_id = $1 AND project_id = $2
            AND (issue_id = $3 OR issue_id IN (
              SELECT id FROM issues
              WHERE org_id = $1 AND project_id = $2 AND merged_into_issue_id = $3
            ))
          ORDER BY received_at DESC
          LIMIT $4
          """,
        [org_id, project_id, issue_id, @recent_limit]
      )

    Enum.map(rows, &to_occurrence/1)
  end

  defp users_affected_for_group(%{org_id: org_id, project_id: project_id}, issue_id) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT COUNT(DISTINCT COALESCE(user_id, user_email))
        FROM error_events
        WHERE org_id = $1 AND project_id = $2
          AND (issue_id = $3 OR issue_id IN (
            SELECT id FROM issues
            WHERE org_id = $1 AND project_id = $2 AND merged_into_issue_id = $3
          ))
          AND (user_id IS NOT NULL OR user_email IS NOT NULL)
        """,
        [org_id, project_id, issue_id]
      )

    count
  end

  defp merged_children_event_count(%{org_id: org_id, project_id: project_id}, issue_id) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT COALESCE(SUM(event_count), 0)
        FROM issues
        WHERE org_id = $1 AND project_id = $2 AND merged_into_issue_id = $3
        """,
        [org_id, project_id, issue_id]
      )

    Decimal.to_integer(count)
  end

  @doc false
  @spec recent(Alplus.Scope.t(), String.t() | [String.t()]) :: [Occurrence.t()]
  def recent(scope, issue_id) when is_binary(issue_id), do: recent(scope, [issue_id])

  def recent(%{org_id: org_id, project_id: project_id}, issue_ids)
      when is_binary(org_id) and is_binary(project_id) and is_list(issue_ids) do
    %{rows: rows} =
      Repo.query!(
        @select_sql <>
          """
          WHERE org_id = $1 AND project_id = $2 AND issue_id = ANY($3)
          ORDER BY received_at DESC
          LIMIT $4
          """,
        [org_id, project_id, issue_ids, @recent_limit]
      )

    Enum.map(rows, &to_occurrence/1)
  end

  @doc false
  @spec fetch(Alplus.Scope.t(), String.t(), String.t()) ::
          {:ok, Occurrence.t()} | {:error, :not_found}
  def fetch(%{org_id: org_id, project_id: project_id}, issue_id, event_id)
      when is_binary(org_id) and is_binary(project_id) and is_binary(issue_id) and
             is_binary(event_id) do
    %{rows: rows} =
      Repo.query!(
        @select_sql <>
          """
          WHERE org_id = $1 AND project_id = $2 AND issue_id = $3 AND event_id = $4
          ORDER BY received_at DESC
          LIMIT 1
          """,
        [org_id, project_id, issue_id, event_id]
      )

    case rows do
      [row] -> {:ok, to_occurrence(row)}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Issue ids on this Source whose stored events carry `tags[key] == value`.

  Used by the Source issue list when a tag chip on the issue page is
  clicked. Tenant-scoped by org, project, and source.
  """
  @spec issue_ids_for_tag(Alplus.Scope.t(), String.t(), String.t(), String.t()) :: [String.t()]
  def issue_ids_for_tag(
        %{org_id: org_id, project_id: project_id},
        source_id,
        key,
        value
      )
      when is_binary(org_id) and is_binary(project_id) and is_binary(source_id) and
             is_binary(key) and is_binary(value) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT DISTINCT issue_id
        FROM error_events
        WHERE org_id = $1 AND project_id = $2 AND source_id = $3
          AND tags ->> $4 = $5
        """,
        [org_id, project_id, source_id, key, value]
      )

    Enum.map(rows, &hd/1)
  end

  @doc false
  @spec users_affected(Alplus.Scope.t(), String.t() | [String.t()]) :: non_neg_integer()
  def users_affected(scope, issue_id) when is_binary(issue_id),
    do: users_affected(scope, [issue_id])

  def users_affected(%{org_id: org_id, project_id: project_id}, issue_ids)
      when is_binary(org_id) and is_binary(project_id) and is_list(issue_ids) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT COUNT(DISTINCT COALESCE(user_id, user_email))
        FROM error_events
        WHERE org_id = $1 AND project_id = $2 AND issue_id = ANY($3)
          AND (user_id IS NOT NULL OR user_email IS NOT NULL)
        """,
        [org_id, project_id, issue_ids]
      )

    count
  end

  defp to_occurrence(row) do
    @columns
    |> Enum.zip(row)
    |> Map.new()
    |> Occurrence.from_row()
  end

  defp merged_children_query(scope, issue_id) do
    Issue
    |> Ash.Query.for_read(:list_for_project, %{project_id: scope.project_id}, actor: scope)
    |> Ash.Query.filter(merged_into_issue_id == ^issue_id)
  end

  defp merged_parent(_scope, %{merged_into_issue_id: nil}), do: nil

  defp merged_parent(scope, issue) do
    case Ash.get(Issue, issue.merged_into_issue_id, actor: scope) do
      {:ok, parent} -> parent
      _ -> nil
    end
  end

  defp normalize_page(page) when is_integer(page) and page > 0, do: page
  defp normalize_page(_page), do: 1
end
