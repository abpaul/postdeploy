defmodule Alplus.Observe.IssueListingTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Observe.{Issue, IssueListing}
  alias Alplus.Scope

  defp project_scope(scope, project), do: Scope.put_project(scope, project.id)

  defp issue_fixture(org, project, source, attrs) do
    now = DateTime.utc_now()

    params =
      Map.merge(
        %{
          org_id: org.id,
          project_id: project.id,
          source_id: source.id,
          environment: source.environment,
          fingerprint: "sha256:" <> String.duplicate("a", 64),
          level: "error",
          title: "Database timeout",
          first_seen_at: now,
          last_seen_at: now
        },
        attrs
      )

    Ash.create!(Issue, params, action: :record, authorize?: false)
  end

  setup do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    {prod, _} = source_fixture(owner_scope, org, project, %{environment: "production"})
    {staging, _} = source_fixture(owner_scope, org, project, %{environment: "staging"})
    scope = project_scope(owner_scope, project)

    %{org: org, project: project, prod: prod, staging: staging, scope: scope}
  end

  test "lists open issues from every Source in the project", %{
    org: org,
    project: project,
    prod: prod,
    staging: staging,
    scope: scope
  } do
    prod_issue = issue_fixture(org, project, prod, %{title: "Prod timeout"})

    staging_issue =
      issue_fixture(org, project, staging, %{
        title: "Staging timeout",
        fingerprint: "sha256:" <> String.duplicate("b", 64)
      })

    listed = IssueListing.list(scope)
    ids = Enum.map(listed, & &1.id)
    assert prod_issue.id in ids
    assert staging_issue.id in ids
    assert Enum.find(listed, &(&1.id == prod_issue.id)).source.name == prod.name
  end

  test "hides merged children and resolved issues by default", %{
    org: org,
    project: project,
    prod: prod,
    scope: scope
  } do
    canonical = issue_fixture(org, project, prod, %{title: "Canonical"})

    child =
      issue_fixture(org, project, prod, %{
        title: "Child",
        fingerprint: "sha256:" <> String.duplicate("c", 64)
      })

    resolved =
      issue_fixture(org, project, prod, %{
        title: "Resolved",
        fingerprint: "sha256:" <> String.duplicate("d", 64)
      })

    Ash.update!(child, %{merged_into_issue_id: canonical.id}, action: :merge, actor: scope)
    Ash.update!(resolved, %{}, action: :resolve, actor: scope)

    ids = scope |> IssueListing.list() |> Enum.map(& &1.id)
    assert canonical.id in ids
    refute child.id in ids
    refute resolved.id in ids

    all_ids = scope |> IssueListing.list(status: "all") |> Enum.map(& &1.id)
    assert resolved.id in all_ids
    refute child.id in all_ids
  end

  test "filters by environment and search", %{
    org: org,
    project: project,
    prod: prod,
    staging: staging,
    scope: scope
  } do
    prod_issue = issue_fixture(org, project, prod, %{title: "Payment timeout"})

    staging_issue =
      issue_fixture(org, project, staging, %{
        title: "Login timeout",
        fingerprint: "sha256:" <> String.duplicate("e", 64)
      })

    env_ids = scope |> IssueListing.list(environment: "staging") |> Enum.map(& &1.id)
    assert staging_issue.id in env_ids
    refute prod_issue.id in env_ids

    search_ids = scope |> IssueListing.list(search: "payment") |> Enum.map(& &1.id)
    assert prod_issue.id in search_ids
    refute staging_issue.id in search_ids
  end

  test "paginates the complete project result set beyond the first 200 rows", %{
    org: org,
    project: project,
    prod: prod,
    scope: scope
  } do
    Enum.each(1..201, fn index ->
      fingerprint =
        "sha256:" <> String.pad_leading(Base.encode16(<<index::32>>, case: :lower), 64, "0")

      seen_at = DateTime.add(DateTime.utc_now(), -index, :second)

      issue_fixture(org, project, prod, %{
        fingerprint: fingerprint,
        title: "Issue #{index}",
        first_seen_at: seen_at,
        last_seen_at: seen_at
      })
    end)

    assert IssueListing.count(scope) == 201
    assert IssueListing.total_pages(IssueListing.count(scope)) == 5

    first_page = IssueListing.list(scope, page: 1, page_size: IssueListing.page_size())
    last_page = IssueListing.list(scope, page: 5, page_size: IssueListing.page_size())

    assert length(first_page) == 50
    assert length(last_page) == 1
    assert MapSet.disjoint?(MapSet.new(first_page, & &1.id), MapSet.new(last_page, & &1.id))
  end

  test "filters one Source's issues by an event tag", %{
    org: org,
    project: project,
    prod: prod,
    scope: scope
  } do
    now = ~U[2026-08-12 09:00:00.000000Z]

    base = fn event_id, tags ->
      %{
        event_id: event_id,
        org_id: org.id,
        project_id: project.id,
        source_id: prod.id,
        environment: prod.environment,
        occurred_at: now,
        received_at: now,
        level: "error",
        sdk_name: "@alplus/sdk",
        sdk_version: "0.3.0",
        exception_type: "TypeError",
        exception_value: event_id,
        frames: [%{file: "/src/app.ts", function: event_id, lineno: 1, in_app: true}],
        tags: tags
      }
    end

    {:ok, %{issue_id: tagged_id}} =
      Alplus.Observe.EventWriter.record(base.("err_tag_1", %{"build" => "main"}))

    {:ok, %{issue_id: other_id}} =
      Alplus.Observe.EventWriter.record(base.("err_tag_2", %{"build" => "next"}))

    opts = [source_id: prod.id, tag: "build:main"]

    assert [listed] = IssueListing.list(scope, opts)
    assert listed.id == tagged_id
    assert IssueListing.count(scope, opts) == 1

    assert other_id in Enum.map(IssueListing.list(scope, source_id: prod.id), & &1.id)
  end
end
