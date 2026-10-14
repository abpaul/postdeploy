# Seed one organization, member, project, changelog, and published entry for the MCP wire contract.
#
# Run with:
#   MIX_ENV=dev mix ash.setup
#   MIX_ENV=dev mix run scripts/seed-mcp-contract.exs
#
# Copy the exported non-secret prefixed project ids into the shell that runs
# verify-mcp-contract.sh. This script does not print or export an access token.

Code.require_file(Path.expand("../test/support/orgs_fixtures.ex", __DIR__))
Logger.configure(level: :warning)
Application.put_env(:alplus, :hibp_req_plug, {Req.Test, Alplus.Accounts.Hibp.Client})

alias Alplus.Changelog
alias Alplus.Mcp
alias Alplus.Mcp.OAuth
alias Alplus.Scope

Req.Test.stub(Alplus.Accounts.Hibp.Client, fn conn -> Req.Test.text(conn, "") end)

Req.Test.stub(Alplus.Turnstile.Client, fn conn ->
  Req.Test.json(conn, %{"success" => true})
end)

suffix = System.unique_integer([:positive])
email = "mcp-contract-#{suffix}@example.com"
user = Alplus.OrgsFixtures.user_fixture(%{email: email})
user_scope = Alplus.OrgsFixtures.scope_fixture(%{user: user})

{org, owner_scope} =
  Alplus.OrgsFixtures.org_fixture(user_scope, %{name: "MCP Contract #{suffix}"})

project =
  Alplus.OrgsFixtures.project_fixture(owner_scope, org, %{
    slug: "mcp-contract-#{suffix}",
    name: "MCP Contract #{suffix}"
  })

no_changelog_project =
  Alplus.OrgsFixtures.project_fixture(owner_scope, org, %{
    slug: "mcp-no-changelog-#{suffix}",
    name: "MCP No Changelog #{suffix}"
  })

project_scope = Scope.put_project(owner_scope, project.id)

{:ok, _changelog} =
  Changelog.create_changelog(
    %{
      org_id: org.id,
      project_id: project.id,
      public_title: "MCP Contract",
      logo_url: "https://example.com/mcp-contract-logo.svg",
      public_slug: "mcp-contract-#{suffix}",
      enabled: true
    },
    actor: project_scope
  )

now = DateTime.utc_now()

{:ok, client} =
  Mcp.cache_oauth_client(
    %{
      issuer: OAuth.issuer(),
      client_id: "https://client.example/mcp-contract-seed-#{suffix}.json",
      client_name: "mcp-contract-seed",
      redirect_uris: ["https://client.example/oauth/callback"],
      fetched_at: now,
      expires_at: DateTime.add(now, 3600, :second)
    },
    authorize?: false
  )

{:ok, grant} =
  Mcp.authorize_oauth_grant(
    %{
      org_id: org.id,
      project_id: project.id,
      user_id: user.id,
      oauth_client_id: client.id,
      issuer: OAuth.issuer(),
      resource: OAuth.resource_uri(),
      scopes: Alplus.Mcp.Scope.all()
    },
    actor: project_scope
  )

grant_scope = %{project_scope | grant_id: grant.id}

{:ok, entry} =
  Changelog.upsert_draft(
    %{
      project_id: project.id,
      grant_id: grant.id,
      external_id: "mcp-contract-seed-#{suffix}",
      markdown: "---\ntitle: MCP contract seed\n---\nPublished contract seed.",
      sources: [
        %{kind: "other", url: "https://example.com/mcp-contract-seed", label: "Contract seed"}
      ]
    },
    actor: grant_scope
  )

{:ok, [revision]} = Changelog.list_revisions(entry, actor: grant_scope)

{:ok, _published_entry} =
  Changelog.publish_entry(entry, revision.revision_number, actor: grant_scope)

IO.puts("export MCP_ORG_ID=#{org.id}")
IO.puts("export MCP_USER_ID=#{user.id}")
IO.puts("export MCP_PROJECT_HANDLE=#{project.id}")
IO.puts("export MCP_NO_CHANGELOG_PROJECT_HANDLE=#{no_changelog_project.id}")
