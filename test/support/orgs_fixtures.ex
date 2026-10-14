defmodule Alplus.OrgsFixtures do
  @moduledoc """
  Test fixtures for Accounts/Orgs/Projects, built through Ash actions (never
  raw `Repo.insert`) so DB constraints and changesets stay exercised.
  """

  alias Alplus.Scope

  @doc """
  A unique email address. Use it whenever a test needs the same address
  twice — an invitation and the account that accepts it, for example.
  A literal address collides across async tests, because `users.email`
  is unique.
  """
  def unique_email, do: "user-#{System.unique_integer([:positive])}@example.com"

  @doc """
  Creates a user via the real registration action and returns it.

  Confirmed by default (`confirmed: true`) via the internal
  `:mark_confirmed` action, since most fixtures need a session that can
  actually reach `/dashboard/*` (ARCHITECTURE.md §10: no useful session
  before verification). Pass `confirmed: false` for tests that exercise the
  pre-confirmation gate itself.
  """
  def user_fixture(attrs \\ %{}) do
    email = Map.get(attrs, :email, unique_email())

    user =
      Ash.create!(
        Alplus.Accounts.User,
        %{
          email: email,
          password: "supersecret1",
          password_confirmation: "supersecret1",
          turnstile_token: "test-fixture-token"
        },
        action: :register_with_password,
        authorize?: false
      )

    if Map.get(attrs, :confirmed, true) do
      Ash.update!(user, %{}, action: :mark_confirmed, authorize?: false)
    else
      user
    end
  end

  @doc "Returns an org-less scope for a fresh user."
  def scope_fixture(attrs \\ %{}) do
    user = Map.get(attrs, :user) || user_fixture()
    Scope.for_user(user.id)
  end

  @doc """
  Creates an org as `scope`'s user (who becomes its owner via
  `Alplus.Orgs.Changes.CreateOwnerMembership`) and returns `{org, owner_scope}`.
  """
  def org_fixture(scope, attrs \\ %{}) do
    name = Map.get(attrs, :name, "Org #{System.unique_integer([:positive])}")

    org =
      Ash.create!(Alplus.Orgs.Organization, %{name: name},
        action: :create,
        actor: scope
      )

    {:ok, owner_scope} = Alplus.Orgs.build_scope(scope, org.id)
    {org, owner_scope}
  end

  @doc """
  Adds `user`'s scope to `org` with `role` (`"admin"` or `"member"`), acting
  as `owner_scope`. Returns the new member's scope for that org.
  """
  def member_fixture(owner_scope, org, user, role \\ "member") do
    subscribed_fixture(org)

    # Most tests need more people than one plan seats. The real `:add_member`
    # action, with its seat check, runs while a seat is free; past that the
    # fixture writes the row directly. `AccessCapacityTest` covers the
    # refusal through the action.
    if seats_taken(org.id) < Alplus.Billing.Package.limit(:members) do
      Ash.create!(
        Alplus.Orgs.Membership,
        %{org_id: org.id, user_id: user.id, role: role},
        action: :add_member,
        actor: owner_scope
      )
    else
      Ash.Seed.seed!(Alplus.Orgs.Membership, %{org_id: org.id, user_id: user.id, role: role})
    end

    {:ok, scope} = Alplus.Orgs.build_scope(Scope.for_user(user.id), org.id)
    scope
  end

  @doc "Creates a project in `org` acting as `scope`."
  def project_fixture(scope, org, attrs \\ %{}) do
    name = Map.get(attrs, :name, "Project #{System.unique_integer([:positive])}")
    project_attrs = attrs |> Map.put(:org_id, org.id) |> Map.put(:name, name)

    Ash.create!(Alplus.Projects.Project, project_attrs,
      action: :create,
      actor: scope
    )
  end

  @doc """
  Creates a Source on `project` acting as `scope`. Returns `{source,
  secret}` — `secret` is the metadata-only credential returned once
  (`nil` for a `:monitor` Source, which mints no credential).
  """
  def source_fixture(scope, org, project, attrs \\ %{}) do
    type = Map.get(attrs, :type, :observe)
    name = Map.get(attrs, :name, "Source #{System.unique_integer([:positive])}")
    environment = Map.get(attrs, :environment, "production")
    hostname = Map.get(attrs, :hostname)

    # Source actions are org AND project scoped, so the actor must carry the
    # project id it is acting within (mirrors the LiveView project scope).
    actor = Alplus.Scope.put_project(scope, project.id)

    source =
      Ash.create!(
        Alplus.Sources.Source,
        %{
          org_id: org.id,
          project_id: project.id,
          type: type,
          name: name,
          environment: environment,
          hostname: hostname
        },
        action: :create,
        actor: actor
      )

    {source, Ash.Resource.get_metadata(source, :secret)}
  end

  @doc "Creates a pending invitation on `org` acting as `scope`. Returns `{invitation, token}`."
  def invitation_fixture(scope, org, attrs \\ %{}) do
    # The default plan permits only the owner. This fixture is used by tests
    # that exercise a successful acceptance, so make the test's intended
    # multi-member state explicit until Billing exposes a plan-change action.
    subscribed_fixture(org)

    email = Map.get(attrs, :email, "invite-#{System.unique_integer([:positive])}@example.com")
    role = Map.get(attrs, :role, "member")

    invitation =
      Ash.create!(Alplus.Orgs.Invitation, %{org_id: org.id, email: email, role: role},
        action: :invite,
        actor: scope
      )

    {invitation, Ash.Resource.get_metadata(invitation, :token)}
  end

  defp seats_taken(org_id) do
    %{rows: [[count]]} =
      Alplus.Repo.query!(
        """
        SELECT (SELECT count(*) FROM memberships WHERE org_id = $1) +
               (SELECT count(*) FROM invitations
                 WHERE org_id = $1 AND status = 'pending' AND expires_at > now())
        """,
        [org_id]
      )

    count
  end

  @doc "Marks an organization as subscribed, as a mirrored active subscription would."
  def subscribed_fixture(org) do
    Alplus.Repo.query!(
      "UPDATE organizations SET plan_status = 'active', plan_id = 'postdeploy' WHERE id = $1",
      [org.id]
    )

    :ok
  end

  @doc "Creates an organization whose trial has expired."
  def expired_trial_fixture(scope, attrs \\ %{}) do
    {org, owner_scope} = org_fixture(scope, attrs)
    expired_at = ~U[2000-01-01 00:00:00.000000Z]

    Alplus.Repo.query!(
      "UPDATE organizations SET trial_ends_at = $1 WHERE id = $2",
      [expired_at, org.id]
    )

    {%{org | trial_ends_at: expired_at}, owner_scope}
  end
end
