defmodule Alplus.Mcp.OAuthPruneTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Mcp
  alias Alplus.Mcp.OAuth
  alias Alplus.Repo

  test "deletes expired codes, access tokens, and stale refresh tokens" do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    actor = Alplus.Scope.put_project(scope, project.id)
    now = DateTime.utc_now()
    grant = authorize_grant!(actor, project, now)
    attrs = %{grant_id: grant.id, resource: OAuth.resource_uri(), scopes: grant.scopes}

    {:ok, expired_code} = issue_code!(grant, attrs)
    {:ok, live_code} = issue_code!(grant, attrs)
    {:ok, expired_access} = Mcp.issue_oauth_access_token(attrs, authorize?: false)
    {:ok, live_access} = Mcp.issue_oauth_access_token(attrs, authorize?: false)
    {:ok, expired_refresh} = Mcp.issue_oauth_refresh_token(attrs, authorize?: false)
    {:ok, old_revoked_refresh} = Mcp.issue_oauth_refresh_token(attrs, authorize?: false)
    {:ok, recent_revoked_refresh} = Mcp.issue_oauth_refresh_token(attrs, authorize?: false)
    {:ok, live_refresh} = Mcp.issue_oauth_refresh_token(attrs, authorize?: false)

    past = DateTime.add(now, -8 * 24 * 60 * 60, :second)
    recent = DateTime.add(now, -60, :second)

    Repo.query!("UPDATE mcp_oauth_authorization_codes SET expires_at = $1 WHERE id = $2", [
      past,
      expired_code.id
    ])

    Repo.query!("UPDATE mcp_oauth_access_tokens SET expires_at = $1 WHERE id = $2", [
      past,
      expired_access.id
    ])

    Repo.query!("UPDATE mcp_oauth_refresh_tokens SET expires_at = $1 WHERE id = $2", [
      past,
      expired_refresh.id
    ])

    Repo.query!("UPDATE mcp_oauth_refresh_tokens SET revoked_at = $1 WHERE id = $2", [
      past,
      old_revoked_refresh.id
    ])

    Repo.query!("UPDATE mcp_oauth_refresh_tokens SET revoked_at = $1 WHERE id = $2", [
      recent,
      recent_revoked_refresh.id
    ])

    assert :ok = OAuth.prune_expired()

    refute exists?("mcp_oauth_authorization_codes", expired_code.id)
    assert exists?("mcp_oauth_authorization_codes", live_code.id)
    refute exists?("mcp_oauth_access_tokens", expired_access.id)
    assert exists?("mcp_oauth_access_tokens", live_access.id)
    refute exists?("mcp_oauth_refresh_tokens", expired_refresh.id)
    refute exists?("mcp_oauth_refresh_tokens", old_revoked_refresh.id)
    assert exists?("mcp_oauth_refresh_tokens", recent_revoked_refresh.id)
    assert exists?("mcp_oauth_refresh_tokens", live_refresh.id)
  end

  defp authorize_grant!(actor, project, now) do
    {:ok, client} =
      Mcp.cache_oauth_client(
        %{
          issuer: OAuth.issuer(),
          client_id:
            "https://client.example/oauth-prune-#{System.unique_integer([:positive])}.json",
          client_name: "Prune client",
          redirect_uris: ["https://client.example/oauth/callback"],
          fetched_at: now,
          expires_at: DateTime.add(now, 3600, :second)
        },
        authorize?: false
      )

    {:ok, grant} =
      Mcp.authorize_oauth_grant(
        %{
          org_id: actor.org_id,
          project_id: project.id,
          user_id: actor.user_id,
          oauth_client_id: client.id,
          issuer: OAuth.issuer(),
          resource: OAuth.resource_uri(),
          scopes: ["projects:read"]
        },
        actor: actor
      )

    grant
  end

  defp issue_code!(grant, attrs) do
    Mcp.issue_oauth_authorization_code(
      %{
        grant_id: grant.id,
        oauth_client_id: grant.oauth_client_id,
        redirect_uri: "https://client.example/oauth/callback",
        resource: attrs.resource,
        scopes: attrs.scopes,
        code_challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
      },
      authorize?: false
    )
  end

  defp exists?(table, id) do
    Repo.one!(from t in table, where: t.id == ^id, select: count(t.id)) == 1
  end
end
