defmodule Alplus.Sources.SourceTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  require Ash.Query

  alias Alplus.Sources.Source

  describe "authorization matrix — Source" do
    setup do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      admin_scope = member_fixture(owner_scope, org, user_fixture(), "admin")
      member_scope = member_fixture(owner_scope, org, user_fixture(), "member")
      outsider_scope = scope_fixture()
      project = project_fixture(owner_scope, org)

      %{
        org: org,
        project: project,
        scopes: %{
          owner: owner_scope,
          admin: admin_scope,
          member: member_scope,
          outsider: outsider_scope
        }
      }
    end

    for {role, can_create?, can_rotate?, can_revoke?, can_read?} <- [
          {:owner, true, true, true, true},
          {:admin, true, true, true, true},
          {:member, false, false, false, true},
          {:outsider, false, false, false, false}
        ] do
      test "#{role}: create=#{can_create?} rotate=#{can_rotate?} revoke=#{can_revoke?} read=#{can_read?}",
           %{project: project, org: org, scopes: scopes} do
        # Source actions are org AND project scoped (mirrors the LiveView
        # project scope), so the actor under test must carry the project id.
        scope = Alplus.Scope.put_project(scopes[unquote(role)], project.id)

        create_result =
          Ash.create(
            Source,
            %{
              org_id: org.id,
              project_id: project.id,
              type: :observe,
              name: "Source",
              environment: "production"
            },
            action: :create,
            actor: scope
          )

        case create_result do
          {:ok, _} -> assert unquote(can_create?)
          {:error, _} -> refute unquote(can_create?)
        end

        {source, _secret} = source_fixture(scopes.owner, org, project, %{environment: "rotate"})

        rotate_result = Ash.update(source, %{}, action: :rotate, actor: scope)

        case rotate_result do
          {:ok, _} -> assert unquote(can_rotate?)
          {:error, _} -> refute unquote(can_rotate?)
        end

        {revocable, _secret} =
          source_fixture(scopes.owner, org, project, %{environment: "revoke"})

        revoke_result = Ash.update(revocable, %{}, action: :revoke, actor: scope)

        case revoke_result do
          {:ok, _} -> assert unquote(can_revoke?)
          {:error, _} -> refute unquote(can_revoke?)
        end

        read_result =
          Source |> Ash.Query.filter(id == ^source.id) |> Ash.read_one(actor: scope)

        case read_result do
          {:ok, %Source{}} -> assert unquote(can_read?)
          {:ok, nil} -> refute unquote(can_read?)
          {:error, _} -> refute unquote(can_read?)
        end
      end
    end
  end

  describe "credential minted per type" do
    test ":observe mints a secret ingest key, returned once via metadata" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      project = project_fixture(owner_scope, org)
      owner_scope = Alplus.Scope.put_project(owner_scope, project.id)

      {source, secret} = source_fixture(owner_scope, org, project, %{type: :observe})

      assert String.starts_with?(secret, "obs_")
      assert byte_size(source.secret_hash) == 64
      refute source.secret_hash == secret
      assert is_binary(source.secret_prefix)
      assert is_nil(source.measure_token)

      refute source |> Map.from_struct() |> Map.values() |> Enum.member?(secret)
      refute inspect(source) =~ secret

      reloaded = Ash.get!(Source, source.id, actor: owner_scope)
      refute inspect(reloaded) =~ secret
    end

    test ":observe keys exclude hyphens; :changelog and :analytics keys keep the URL-safe alphabet" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      project = project_fixture(owner_scope, org)
      owner_scope = Alplus.Scope.put_project(owner_scope, project.id)

      minted =
        for type <- [:observe, :changelog, :analytics], n <- 1..4 do
          {source, secret} =
            source_fixture(owner_scope, org, project, %{type: type, environment: "env-#{n}"})

          {type, source, secret}
        end

      for {type, source, secret} <- minted do
        [_prefix, body] = String.split(secret, "_", parts: 2)
        assert byte_size(body) == 43
        assert body =~ ~r/\A[A-Za-z0-9_-]+\z/
        assert source.secret_prefix == String.slice(body, 0, 8)
        assert source.secret_hash == Alplus.Security.BearerToken.hash(secret)

        if type == :observe do
          refute body =~ "-"
          assert {:ok, %Source{id: id}} = Source.authenticate_observe(secret)
          assert id == source.id
        end
      end

      for prefix <- ["chg", "pda"] do
        assert Enum.any?(1..200, fn _ ->
                 {secret, _hash, _prefix} = Alplus.Security.BearerToken.generate(prefix)
                 secret =~ "-"
               end)
      end
    end

    test ":measure mints a public token stored in the clear" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      project = project_fixture(owner_scope, org)
      owner_scope = Alplus.Scope.put_project(owner_scope, project.id)

      {source, secret} = source_fixture(owner_scope, org, project, %{type: :measure})

      assert String.starts_with?(secret, "msr_")
      assert source.measure_token == secret
      assert is_nil(source.secret_hash)
      assert is_nil(source.secret_prefix)

      # Unlike the Observe secret, the Measure token is public: a later
      # read still shows it in the clear.
      reloaded = Ash.get!(Source, source.id, actor: owner_scope)
      assert reloaded.measure_token == secret
    end

    test ":monitor mints no ingest credential" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      project = project_fixture(owner_scope, org)

      {source, secret} = source_fixture(owner_scope, org, project, %{type: :monitor})

      assert is_nil(secret)
      assert is_nil(source.secret_hash)
      assert is_nil(source.secret_prefix)
      assert is_nil(source.measure_token)
    end
  end

  describe "rotate" do
    test ":observe rotate keeps the old secret working during the grace window" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      project = project_fixture(owner_scope, org)
      owner_scope = Alplus.Scope.put_project(owner_scope, project.id)
      {source, old_secret} = source_fixture(owner_scope, org, project, %{type: :observe})

      assert {:ok, %Source{id: id}} = Source.authenticate_observe(old_secret)
      assert id == source.id

      rotated =
        Ash.update!(source, %{grace_period_seconds: 3600}, action: :rotate, actor: owner_scope)

      new_secret = Ash.Resource.get_metadata(rotated, :secret)
      refute new_secret == old_secret

      assert {:ok, %Source{id: ^id}} = Source.authenticate_observe(new_secret)
      assert {:ok, %Source{id: ^id}} = Source.authenticate_observe(old_secret)

      source2 = Ash.get!(Source, source.id, actor: owner_scope)

      rotated2 =
        Ash.update!(source2, %{grace_period_seconds: 0}, action: :rotate, actor: owner_scope)

      newer_secret = Ash.Resource.get_metadata(rotated2, :secret)

      assert {:ok, %Source{id: ^id}} = Source.authenticate_observe(newer_secret)
      assert {:error, :not_found} = Source.authenticate_observe(new_secret)
    end

    test ":measure rotate replaces the token outright, no grace window" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      project = project_fixture(owner_scope, org)
      owner_scope = Alplus.Scope.put_project(owner_scope, project.id)
      {source, old_token} = source_fixture(owner_scope, org, project, %{type: :measure})

      rotated = Ash.update!(source, %{}, action: :rotate, actor: owner_scope)
      new_token = Ash.Resource.get_metadata(rotated, :secret)

      refute new_token == old_token
      assert rotated.measure_token == new_token
    end

    test ":monitor rotate is rejected — there is no credential to rotate" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      project = project_fixture(owner_scope, org)
      {source, _secret} = source_fixture(owner_scope, org, project, %{type: :monitor})

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(source, %{}, action: :rotate, actor: owner_scope)
    end
  end

  describe "revoke" do
    test "a revoked Observe source never authenticates again" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      project = project_fixture(owner_scope, org)
      owner_scope = Alplus.Scope.put_project(owner_scope, project.id)
      {source, secret} = source_fixture(owner_scope, org, project, %{type: :observe})

      assert {:ok, revoked} = Ash.update(source, %{}, action: :revoke, actor: owner_scope)
      assert revoked.status == :revoked

      assert {:error, :not_found} = Source.authenticate_observe(secret)
    end
  end

  describe "uniqueness — one Source per (project, type, environment)" do
    test "rejects a duplicate active Source, but allows reuse after revocation" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      project = project_fixture(owner_scope, org)
      owner_scope = Alplus.Scope.put_project(owner_scope, project.id)

      {source, _secret} =
        source_fixture(owner_scope, org, project, %{type: :observe, environment: "production"})

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(
                 Source,
                 %{
                   org_id: org.id,
                   project_id: project.id,
                   type: :observe,
                   name: "Dup",
                   environment: "production"
                 },
                 action: :create,
                 actor: owner_scope
               )

      Ash.update!(source, %{}, action: :revoke, actor: owner_scope)

      assert {:ok, _new_source} =
               Ash.create(
                 Source,
                 %{
                   org_id: org.id,
                   project_id: project.id,
                   type: :observe,
                   name: "Replacement",
                   environment: "production"
                 },
                 action: :create,
                 actor: owner_scope
               )
    end

    test "the same environment is fine across different product types" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      project = project_fixture(owner_scope, org)
      owner_scope = Alplus.Scope.put_project(owner_scope, project.id)

      assert {:ok, _observe} =
               source_fixture(owner_scope, org, project, %{type: :observe, environment: "prod"})
               |> then(fn {source, _} -> {:ok, source} end)

      assert {:ok, _measure} =
               Ash.create(
                 Source,
                 %{
                   org_id: org.id,
                   project_id: project.id,
                   type: :measure,
                   name: "Measure prod",
                   environment: "prod"
                 },
                 action: :create,
                 actor: owner_scope
               )
    end
  end

  describe "uniqueness — measure Sources are first-class sites (issue #34, Model A)" do
    test "a project can hold multiple active measure Sources, even in the same environment" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      project = project_fixture(owner_scope, org)
      owner_scope = Alplus.Scope.put_project(owner_scope, project.id)

      assert {:ok, first} =
               Ash.create(
                 Source,
                 %{
                   org_id: org.id,
                   project_id: project.id,
                   type: :measure,
                   name: "Production site A",
                   environment: "production"
                 },
                 action: :create,
                 actor: owner_scope
               )

      assert {:ok, second} =
               Ash.create(
                 Source,
                 %{
                   org_id: org.id,
                   project_id: project.id,
                   type: :measure,
                   name: "Production site B",
                   environment: "production"
                 },
                 action: :create,
                 actor: owner_scope
               )

      refute first.id == second.id
      assert first.status == :active
      assert second.status == :active
    end

    test "observe still allows only one active Source per (project, type, environment)" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      project = project_fixture(owner_scope, org)
      owner_scope = Alplus.Scope.put_project(owner_scope, project.id)

      {_source, _secret} =
        source_fixture(owner_scope, org, project, %{type: :observe, environment: "production"})

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(
                 Source,
                 %{
                   org_id: org.id,
                   project_id: project.id,
                   type: :observe,
                   name: "Dup",
                   environment: "production"
                 },
                 action: :create,
                 actor: owner_scope
               )
    end

    test "monitor still allows only one active Source per (project, type, environment)" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      project = project_fixture(owner_scope, org)
      owner_scope = Alplus.Scope.put_project(owner_scope, project.id)

      {_source, _secret} =
        source_fixture(owner_scope, org, project, %{type: :monitor, environment: "production"})

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(
                 Source,
                 %{
                   org_id: org.id,
                   project_id: project.id,
                   type: :monitor,
                   name: "Dup",
                   environment: "production"
                 },
                 action: :create,
                 actor: owner_scope
               )
    end
  end

  describe "cross-tenant" do
    test "a foreign org id behaves as not-found on create, not a policy error message" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      project = project_fixture(owner_scope, org)

      other_owner = scope_fixture()
      {other_org, _other_owner_scope} = org_fixture(other_owner)

      # Must surface as the ProjectInOrg not-found validation, never
      # Ash.Error.Forbidden — a 403-shaped error would disclose that
      # `project.id` exists to an actor with no claim on it.
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Ash.create(
                 Source,
                 %{
                   org_id: other_org.id,
                   project_id: project.id,
                   type: :observe,
                   name: "Source",
                   environment: "production"
                 },
                 action: :create,
                 actor: owner_scope
               )

      assert Enum.any?(errors, &match?(%{field: :project_id, message: "does not exist"}, &1))
    end

    test "an owner cannot attach a Source to another org's project" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)

      other_owner = scope_fixture()
      {other_org, other_owner_scope} = org_fixture(other_owner)
      other_project = project_fixture(other_owner_scope, other_org)

      # Org A's owner pairs their own org_id with org B's project id. Must
      # surface as not-found, never Ash.Error.Forbidden.
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Ash.create(
                 Source,
                 %{
                   org_id: org.id,
                   project_id: other_project.id,
                   type: :observe,
                   name: "Source",
                   environment: "production"
                 },
                 action: :create,
                 actor: owner_scope
               )

      assert Enum.any?(errors, &match?(%{field: :project_id, message: "does not exist"}, &1))
    end

    test "a revoked Source cannot be rotated" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      project = project_fixture(owner_scope, org)
      owner_scope = Alplus.Scope.put_project(owner_scope, project.id)
      {source, _secret} = source_fixture(owner_scope, org, project, %{type: :observe})

      {:ok, revoked} = Ash.update(source, %{}, action: :revoke, actor: owner_scope)

      assert {:error, _} = Ash.update(revoked, %{}, action: :rotate, actor: owner_scope)
    end

    test "a second org's owner cannot read, rotate, or revoke another org's Source" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      project = project_fixture(owner_scope, org)
      {source, _secret} = source_fixture(owner_scope, org, project, %{type: :observe})

      other_owner = scope_fixture()
      {_other_org, other_owner_scope} = org_fixture(other_owner)

      assert {:ok, nil} =
               Source
               |> Ash.Query.filter(id == ^source.id)
               |> Ash.read_one(actor: other_owner_scope)

      assert {:error, _} =
               Ash.update(source, %{}, action: :rotate, actor: other_owner_scope)

      assert {:error, _} =
               Ash.update(source, %{}, action: :revoke, actor: other_owner_scope)
    end

    test "a member of a sibling project, same org, cannot read, rotate, or revoke the Source" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      subscribed_fixture(org)
      project_b = project_fixture(owner_scope, org)
      project_b_scope = Alplus.Scope.put_project(owner_scope, project_b.id)
      {source, _secret} = source_fixture(owner_scope, org, project_b, %{type: :observe})

      # Same org, different project (ADR 0001 bug: this Source used to be
      # loadable, rotatable, and revocable through project A's URL).
      project_a = project_fixture(owner_scope, org)
      project_a_scope = Alplus.Scope.put_project(owner_scope, project_a.id)

      assert {:ok, nil} =
               Source
               |> Ash.Query.filter(id == ^source.id)
               |> Ash.read_one(actor: project_a_scope)

      assert {:error, _} =
               Ash.update(source, %{}, action: :rotate, actor: project_a_scope)

      assert {:error, _} =
               Ash.update(source, %{}, action: :revoke, actor: project_a_scope)

      # Sanity: the same actor, correctly scoped to project B, still can.
      assert {:ok, %Source{}} =
               Source
               |> Ash.Query.filter(id == ^source.id)
               |> Ash.read_one(actor: project_b_scope)
    end
  end

  describe "rename" do
    setup do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      project = project_fixture(owner_scope, org)
      scope = Alplus.Scope.put_project(owner_scope, project.id)
      {source, _secret} = source_fixture(scope, org, project, %{type: :observe, name: "AWS"})

      %{org: org, project: project, scope: scope, owner_scope: owner_scope, source: source}
    end

    test "an owner renames a Source without touching its credential", %{
      scope: scope,
      source: source
    } do
      assert {:ok, renamed} =
               Alplus.Sources.rename_source(source, %{name: "PostDeploy errors"}, actor: scope)

      assert renamed.name == "PostDeploy errors"
      assert renamed.type == source.type
      assert renamed.environment == source.environment
      assert renamed.secret_prefix == source.secret_prefix
    end

    test "the same actor scoped to another project cannot rename the Source", %{
      org: org,
      owner_scope: owner_scope,
      source: source
    } do
      other_project = project_fixture(owner_scope, org, %{name: "Other project"})
      other_scope = Alplus.Scope.put_project(owner_scope, other_project.id)

      assert {:error, _error} =
               Alplus.Sources.rename_source(source, %{name: "Stolen"}, actor: other_scope)

      assert {:ok, %Source{name: "AWS"}} = Ash.get(Source, source.id, authorize?: false)
    end

    test "a member may not rename a Source", %{
      org: org,
      project: project,
      owner_scope: owner_scope,
      source: source
    } do
      member_scope =
        owner_scope
        |> member_fixture(org, user_fixture(), "member")
        |> Alplus.Scope.put_project(project.id)

      assert {:error, _error} =
               Alplus.Sources.rename_source(source, %{name: "Stolen"}, actor: member_scope)
    end
  end
end
