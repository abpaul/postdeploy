defmodule Alplus.Observe.ReleaseTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Observe.{Issue, Release, ReleaseArtifact}
  alias Alplus.Scope

  defp project_scope(scope, project), do: Scope.put_project(scope, project.id)

  defp release_fixture(scope, org, project) do
    Ash.create!(
      Release,
      %{
        org_id: org.id,
        project_id: project.id,
        environment: "production",
        version: "2026.08.11",
        commit_sha: String.duplicate("a", 40),
        released_at: ~U[2026-08-11 13:00:00.000000Z]
      },
      actor: project_scope(scope, project)
    )
  end

  test "an owner creates a release and an artifact" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)
    release = release_fixture(owner_scope, org, project)

    artifact =
      Ash.create!(
        ReleaseArtifact,
        %{
          org_id: org.id,
          project_id: project.id,
          release_id: release.id,
          name: "app.js.map",
          type: "source_map",
          storage_key: "releases/#{release.id}/app.js.map",
          sha256: String.duplicate("b", 64),
          byte_size: 512
        },
        actor: scope
      )

    assert [listed_artifact] =
             ReleaseArtifact
             |> Ash.Query.for_read(:list_for_release, %{release_id: release.id}, actor: scope)
             |> Ash.read!(actor: scope)

    assert listed_artifact.id == artifact.id
  end

  test "issue resolution cannot point to a release from another tenant" do
    {org_a, owner_a} = org_fixture(scope_fixture())
    project_a = project_fixture(owner_a, org_a)
    scope_a = project_scope(owner_a, project_a)

    issue =
      Ash.create!(
        Issue,
        %{
          org_id: org_a.id,
          project_id: project_a.id,
          environment: "production",
          fingerprint: "sha256:" <> String.duplicate("c", 64),
          level: "error",
          title: "Timeout",
          first_seen_at: ~U[2026-08-11 13:00:00.000000Z],
          last_seen_at: ~U[2026-08-11 13:00:00.000000Z]
        },
        action: :record,
        authorize?: false
      )

    {org_b, owner_b} = org_fixture(scope_fixture())
    project_b = project_fixture(owner_b, org_b)
    foreign_release = release_fixture(owner_b, org_b, project_b)

    assert_raise Ash.Error.Unknown, ~r/issues_resolved_release_scope_fkey/, fn ->
      Ash.update!(issue, %{resolved_in_release_id: foreign_release.id},
        action: :resolve,
        actor: scope_a
      )
    end
  end

  test "deleting a release clears only its resolved issue reference" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)
    release = release_fixture(owner_scope, org, project)

    issue =
      Ash.create!(
        Issue,
        %{
          org_id: org.id,
          project_id: project.id,
          environment: "production",
          fingerprint: "sha256:" <> String.duplicate("d", 64),
          level: "error",
          title: "Timeout",
          first_seen_at: ~U[2026-08-11 13:00:00.000000Z],
          last_seen_at: ~U[2026-08-11 13:00:00.000000Z]
        },
        action: :record,
        authorize?: false
      )

    resolved_issue =
      Ash.update!(issue, %{resolved_in_release_id: release.id}, action: :resolve, actor: scope)

    assert %{num_rows: 1} =
             Alplus.Repo.query!("DELETE FROM releases WHERE id = $1", [release.id])

    issue_id = issue.id
    org_id = org.id
    project_id = project.id

    assert %Issue{
             id: ^issue_id,
             org_id: ^org_id,
             project_id: ^project_id,
             resolved_in_release_id: nil
           } =
             Ash.get!(Issue, resolved_issue.id, actor: scope)
  end
end
