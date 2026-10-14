defmodule Alplus.Mcp.OAuthGrantManagementTest do
  @moduledoc """
  Domain contract for Connected MCP Clients (issue #139).

  Settings lists and revokes through `list_oauth_grants/1` and
  `revoke_oauth_grant/2`. These tests pin that policy and the loaded
  display row independently of LiveView.
  """

  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Accounts.User
  alias Alplus.Mcp
  alias Alplus.Mcp.Audit
  alias Alplus.Mcp.{OAuth, Principal, Scope}

  @granted_scopes ["projects:read", "monitor:read"]
  @scope_labels ["Projects read", "Monitor read"]

  setup do
    owner_user = named_user("Grant Owner")
    {org, owner_scope} = org_fixture(scope_fixture(%{user: owner_user}), %{name: "Acme"})
    project = project_fixture(owner_scope, org, %{name: "Production"})

    admin_user = named_user("Grant Admin")
    admin_scope = member_fixture(owner_scope, org, admin_user, "admin")

    member_scope = member_fixture(owner_scope, org, user_fixture(), "member")

    {foreign_org, foreign_scope} =
      org_fixture(scope_fixture(), %{name: "Other Org"})

    foreign_project = project_fixture(foreign_scope, foreign_org, %{name: "Foreign"})

    %{
      org: org,
      project: project,
      owner_user: owner_user,
      owner: Alplus.Scope.put_project(owner_scope, project.id),
      admin_user: admin_user,
      admin: Alplus.Scope.put_project(admin_scope, project.id),
      member: Alplus.Scope.put_project(member_scope, project.id),
      foreign_org: foreign_org,
      foreign_project: foreign_project,
      foreign: Alplus.Scope.put_project(foreign_scope, foreign_project.id)
    }
  end

  describe "list_oauth_grants/1" do
    test "returns the selected org's active grants with client, account, and project display loads",
         context do
      owner_client = cache_client!("Cursor")
      admin_client = cache_client!("Claude")
      foreign_client = cache_client!("Stranger")

      owner_grant = authorize_grant!(context.owner, owner_client)
      admin_grant = authorize_grant!(context.admin, admin_client)
      _foreign_grant = authorize_grant!(context.foreign, foreign_client)

      revoked = authorize_grant!(context.owner, cache_client!("Revoked"))
      assert {:ok, _} = Mcp.revoke_oauth_grant(revoked, actor: context.owner)

      {access_token, refresh_token} = issue_tokens!(owner_grant)
      assert {:ok, %Principal{}} = OAuth.authenticate_access_token(access_token)

      assert {:ok, listed} = Mcp.list_oauth_grants(actor: context.owner)

      assert MapSet.new(Enum.map(listed, & &1.id)) ==
               MapSet.new([owner_grant.id, admin_grant.id])

      owner_row = Enum.find(listed, &(&1.id == owner_grant.id))
      admin_row = Enum.find(listed, &(&1.id == admin_grant.id))

      assert_display_row(owner_row, %{
        client_name: "Cursor",
        user: context.owner_user,
        org_name: "Acme",
        project_name: "Production"
      })

      assert_display_row(admin_row, %{
        client_name: "Claude",
        user: context.admin_user,
        org_name: "Acme",
        project_name: "Production"
      })

      assert %DateTime{} = owner_row.last_used_at
      assert owner_row.inserted_at == owner_grant.inserted_at

      refute_secrets(listed, [access_token, refresh_token])

      assert {:ok, admin_listed} = Mcp.list_oauth_grants(actor: context.admin)

      assert MapSet.new(Enum.map(admin_listed, & &1.id)) ==
               MapSet.new([owner_grant.id, admin_grant.id])
    end

    test "hides current-org grants from ordinary members and isolates other orgs", context do
      visible = authorize_grant!(context.owner, cache_client!("Visible"))
      foreign_grant = authorize_grant!(context.foreign, cache_client!("Hidden"))

      assert {:ok, []} = Mcp.list_oauth_grants(actor: context.member)

      assert {:ok, [owner_listed]} = Mcp.list_oauth_grants(actor: context.owner)
      assert owner_listed.id == visible.id

      assert {:ok, [admin_listed]} = Mcp.list_oauth_grants(actor: context.admin)
      assert admin_listed.id == visible.id

      assert {:ok, [foreign_listed]} = Mcp.list_oauth_grants(actor: context.foreign)
      assert foreign_listed.id == foreign_grant.id
    end
  end

  describe "revoke_oauth_grant/2" do
    test "owner revoke marks the grant revoked and fails access plus refresh immediately",
         context do
      client = cache_client!("Cursor")
      grant = authorize_grant!(context.owner, client)
      {access_token, refresh_token} = issue_tokens!(grant)

      assert {:ok, %Principal{}} = OAuth.authenticate_access_token(access_token)

      assert {:ok, revoked} = Mcp.revoke_oauth_grant(grant, actor: context.owner)
      assert %DateTime{} = revoked.revoked_at

      assert {:ok, persisted} = Mcp.get_oauth_grant(grant.id, actor: context.owner)
      assert %DateTime{} = persisted.revoked_at

      assert {:ok, []} = Mcp.list_oauth_grants(actor: context.owner)

      assert {:error, :revoked} = OAuth.authenticate_access_token(access_token)
      assert {:error, :invalid_grant} = OAuth.refresh_token(refresh_params(refresh_token, client))
    end

    test "admin can revoke another member's grant in the selected org", context do
      client = cache_client!("Claude")
      grant = authorize_grant!(context.owner, client)
      {access_token, refresh_token} = issue_tokens!(grant)

      assert {:ok, revoked} = Mcp.revoke_oauth_grant(grant, actor: context.admin)
      assert %DateTime{} = revoked.revoked_at
      assert {:ok, []} = Mcp.list_oauth_grants(actor: context.admin)
      assert {:error, :revoked} = OAuth.authenticate_access_token(access_token)
      assert {:error, :invalid_grant} = OAuth.refresh_token(refresh_params(refresh_token, client))
    end

    test "ordinary members cannot revoke and tokens stay live", context do
      client = cache_client!("Cursor")
      grant = authorize_grant!(context.owner, client)
      {access_token, refresh_token} = issue_tokens!(grant)

      assert {:error, %Ash.Error.Forbidden{}} =
               Mcp.revoke_oauth_grant(grant, actor: context.member)

      assert {:ok, []} = Mcp.list_oauth_grants(actor: context.member)

      assert {:ok, [still_listed]} = Mcp.list_oauth_grants(actor: context.owner)
      assert still_listed.id == grant.id
      assert is_nil(still_listed.revoked_at)

      assert {:ok, %Principal{}} = OAuth.authenticate_access_token(access_token)
      assert {:ok, _rotated} = OAuth.refresh_token(refresh_params(refresh_token, client))
    end

    test "cross-org actors cannot list or revoke and tokens stay live", context do
      client = cache_client!("Cursor")
      grant = authorize_grant!(context.owner, client)
      {access_token, refresh_token} = issue_tokens!(grant)

      assert {:ok, []} = Mcp.list_oauth_grants(actor: context.foreign)

      assert {:error, %Ash.Error.Forbidden{}} =
               Mcp.revoke_oauth_grant(grant, actor: context.foreign)

      assert {:ok, [still_listed]} = Mcp.list_oauth_grants(actor: context.owner)
      assert still_listed.id == grant.id
      assert is_nil(still_listed.revoked_at)

      assert {:ok, %Principal{}} = OAuth.authenticate_access_token(access_token)
      assert {:ok, _rotated} = OAuth.refresh_token(refresh_params(refresh_token, client))
    end
  end

  describe "list_oauth_grant_labels/3" do
    test "projects only id and client label for every member role, including revoked grants",
         context do
      owner_grant = authorize_grant!(context.owner, cache_client!("Owner"))
      admin_grant = authorize_grant!(context.owner, cache_client!("Admin"))
      member_grant = authorize_grant!(context.owner, cache_client!("Member"))
      revoked = authorize_grant!(context.owner, cache_client!("Revoked"))
      assert {:ok, _} = Mcp.revoke_oauth_grant(revoked, actor: context.owner)

      {:ok, organization_grant} =
        Mcp.authorize_oauth_grant(
          %{
            org_id: context.org.id,
            project_id: nil,
            scope_mode: "organization",
            user_id: context.owner.user_id,
            oauth_client_id: cache_client!("Organization").id,
            issuer: OAuth.issuer(),
            resource: OAuth.resource_uri(context.org.public_token),
            scopes: ["changelog:read"]
          },
          actor: context.owner
        )

      ids = [
        owner_grant.id,
        admin_grant.id,
        member_grant.id,
        organization_grant.id,
        revoked.id
      ]

      for actor <- [context.owner, context.admin, context.member] do
        assert {:ok, labels} = Mcp.list_oauth_grant_labels(context.project.id, ids, actor: actor)

        assert Enum.sort(labels, &(&1.client_display_name <= &2.client_display_name))
               |> Enum.map(& &1.client_display_name) ==
                 ["Admin", "Member", "Organization", "Owner", "Revoked"]

        assert Enum.all?(labels, &(Map.keys(&1) |> Enum.sort() == [:client_display_name, :id]))
      end

      assert {:ok, []} =
               Mcp.list_oauth_grant_labels(context.project.id, ids, actor: context.foreign)
    end
  end

  test "authorization choices batch projects across memberships", context do
    assert {:ok, choices} = OAuth.authorization_choices(context.owner_user)
    assert Enum.map(choices, & &1.organization.id) == [context.org.id]
    assert Enum.all?(choices, &(length(&1.projects) == 1))
  end

  test "audit metadata redacts OAuth codes and tokens", context do
    grant = authorize_grant!(context.owner, cache_client!("Audit"))
    principal = Principal.from_oauth(grant, grant.scopes)

    assert :ok =
             Audit.record(%{
               actor: principal,
               org_id: context.org.id,
               project_id: context.project.id,
               tool: "projects.list",
               correlation_id: principal.correlation_id,
               request_metadata: %{
                 "code" => "mcoac_secret",
                 "code_verifier" => "pkce-verifier-secret",
                 "code_challenge" => "pkce-challenge-secret",
                 "refresh_token" => "mcort_secret",
                 "access_token" => "mcoat_secret",
                 "limit" => 5
               }
             })

    assert %{rows: [[metadata]]} =
             Alplus.Repo.query!(
               "SELECT metadata FROM audit_logs WHERE request_id = $1 ORDER BY inserted_at DESC LIMIT 1",
               [principal.correlation_id]
             )

    refute metadata["code"]
    refute metadata["code_verifier"]
    refute metadata["code_challenge"]
    refute metadata["refresh_token"]
    refute metadata["access_token"]
    assert metadata["limit"] == 5
  end

  defp named_user(name) do
    user = user_fixture()

    Ash.update!(user, %{name: name},
      action: :update_profile,
      actor: Alplus.Scope.for_user(user.id)
    )
  end

  defp cache_client!(name) do
    now = DateTime.utc_now()

    {:ok, client} =
      Mcp.cache_oauth_client(
        %{
          issuer: OAuth.issuer(),
          client_id:
            "https://client.example/oauth-grant-mgmt-#{System.unique_integer([:positive])}.json",
          client_name: name,
          redirect_uris: ["https://client.example/oauth/callback"],
          fetched_at: now,
          expires_at: DateTime.add(now, 3600, :second)
        },
        authorize?: false
      )

    client
  end

  defp authorize_grant!(actor, client, scopes \\ @granted_scopes) do
    {:ok, grant} =
      Mcp.authorize_oauth_grant(
        %{
          org_id: actor.org_id,
          project_id: actor.project_id,
          user_id: actor.user_id,
          oauth_client_id: client.id,
          issuer: OAuth.issuer(),
          resource: OAuth.resource_uri(),
          scopes: scopes
        },
        actor: actor
      )

    grant
  end

  defp issue_tokens!(grant) do
    attrs = %{
      grant_id: grant.id,
      resource: OAuth.resource_uri(),
      scopes: grant.scopes
    }

    {:ok, access_token} = Mcp.issue_oauth_access_token(attrs, authorize?: false)
    {:ok, refresh_token} = Mcp.issue_oauth_refresh_token(attrs, authorize?: false)

    access = Ash.Resource.get_metadata(access_token, :token)
    refresh = Ash.Resource.get_metadata(refresh_token, :token)
    assert is_binary(access) and access != ""
    assert is_binary(refresh) and refresh != ""
    {access, refresh}
  end

  defp refresh_params(refresh_token, client) do
    %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token,
      "client_id" => client.client_id,
      "resource" => OAuth.resource_uri()
    }
  end

  defp assert_display_row(grant, %{
         client_name: client_name,
         user: %User{} = user,
         org_name: org_name,
         project_name: project_name
       }) do
    assert Ash.Resource.loaded?(grant, :oauth_client)
    assert Ash.Resource.loaded?(grant, :user)
    assert Ash.Resource.loaded?(grant, :organization)
    assert Ash.Resource.loaded?(grant, :project)
    refute Ash.Resource.loaded?(grant, :authorization_codes)
    refute Ash.Resource.loaded?(grant, :access_tokens)

    assert grant.oauth_client.client_name == client_name
    assert grant.user.id == user.id
    assert grant.user.name == user.name
    assert to_string(grant.user.email) == to_string(user.email)
    assert grant.organization.name == org_name
    assert grant.project.name == project_name
    assert grant.scopes == @granted_scopes
    assert Scope.labels(Enum.join(grant.scopes, " ")) == @scope_labels
    assert %DateTime{} = grant.inserted_at
    assert is_nil(grant.revoked_at)
  end

  defp refute_secrets(listed, secrets) do
    dumped = inspect(listed)

    Enum.each(secrets, fn secret ->
      refute dumped =~ secret
    end)
  end
end
