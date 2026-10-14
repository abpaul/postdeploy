defmodule Alplus.Seo.ProfileTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Seo.{Competitor, Profile}

  setup do
    owner = scope_fixture()
    {org, owner_scope} = org_fixture(owner)
    project = project_fixture(owner_scope, org)
    owner_scope = Alplus.Scope.put_project(owner_scope, project.id)

    {source, _token} =
      source_fixture(owner_scope, org, project, %{
        type: :measure,
        hostname: "example.com"
      })

    %{org: org, project: project, owner_scope: owner_scope, source: source}
  end

  test "an owner creates one profile for its Measure site", %{
    org: org,
    project: project,
    owner_scope: scope,
    source: source
  } do
    assert {:ok, %Profile{source_id: source_id, target: "example.com"}} =
             Ash.create(
               Profile,
               %{
                 org_id: org.id,
                 project_id: project.id,
                 source_id: source.id,
                 target: "example.com",
                 location_code: 2840,
                 language_code: "en"
               },
               actor: scope
             )

    assert source_id == source.id
  end

  test "a profile cannot target a different hostname", %{
    org: org,
    project: project,
    owner_scope: scope,
    source: source
  } do
    assert {:error, %Ash.Error.Invalid{}} =
             Ash.create(
               Profile,
               %{
                 org_id: org.id,
                 project_id: project.id,
                 source_id: source.id,
                 target: "other.example",
                 location_code: 2840,
                 language_code: "en"
               },
               actor: scope
             )
  end

  test "the database rejects a fourth competitor", %{
    org: org,
    project: project,
    owner_scope: scope,
    source: source
  } do
    profile =
      Ash.create!(
        Profile,
        %{
          org_id: org.id,
          project_id: project.id,
          source_id: source.id,
          target: "example.com",
          location_code: 2840,
          language_code: "en"
        },
        actor: scope
      )

    for target <- ~w(one.example two.example three.example) do
      assert {:ok, %Competitor{}} =
               Ash.create(
                 Competitor,
                 %{
                   org_id: org.id,
                   project_id: project.id,
                   profile_id: profile.id,
                   target: target
                 },
                 actor: scope
               )
    end

    assert {:error, _error} =
             Ash.create(
               Competitor,
               %{
                 org_id: org.id,
                 project_id: project.id,
                 profile_id: profile.id,
                 target: "four.example"
               },
               actor: scope
             )
  end
end
