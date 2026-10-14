defmodule Alplus.Billing.AccessConcurrencyTest do
  @moduledoc """
  Capacity gates under real concurrency, through the public Ash create
  actions the console calls.

  Warning: these tests commit rows. Read `Alplus.ConcurrencyCase` first.
  """

  # Not async: these tests run outside the Ecto sandbox on real connections.
  use Alplus.ConcurrencyCase, async: false

  alias Alplus.Orgs.Invitation
  alias Alplus.Projects.Project

  test "two concurrent invitations cannot both take the last seat" do
    scope = scope_fixture()
    {org, owner_scope} = org_fixture(scope)
    delete_after_test([org.id], [scope.user_id])

    # Pro seats five. The owner and three pending invitations leave one seat.
    subscribed_fixture(org)
    for index <- 0..2, do: {:ok, _} = invite(org, owner_scope, index)

    results = race_for_org(org.id, 2, fn index -> invite(org, owner_scope, index) end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
    assert seats_taken(org.id) == 5
  end

  test "two concurrent creates cannot both take the last project slot" do
    scope = scope_fixture()
    {org, owner_scope} = org_fixture(scope)
    delete_after_test([org.id], [scope.user_id])

    subscribed_fixture(org)
    limit = Alplus.Billing.Package.limit(:projects)
    for index <- 1..(limit - 1), do: {:ok, _} = create_project(org, owner_scope, index)

    # Exactly one project slot remains.
    results =
      race_for_org(org.id, 2, fn index ->
        create_project(org, owner_scope, index + limit)
      end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
    assert active_projects(org.id) == limit
  end

  test "an invitation that expires during the lock wait frees its seat" do
    scope = scope_fixture()
    {org, owner_scope} = org_fixture(scope)
    delete_after_test([org.id], [scope.user_id])

    subscribed_fixture(org)
    {:ok, expiring} = invite(org, owner_scope, 1)
    {:ok, _} = invite(org, owner_scope, 2)
    {:ok, _} = invite(org, owner_scope, 3)
    {:ok, _} = invite(org, owner_scope, 4)
    expire_in(expiring, 300)

    # The seat count must read the clock when it runs, not when its blocked
    # transaction started, or this valid invitation is refused a free seat.
    [result] =
      race_for_org(org.id, 1, fn index -> invite(org, owner_scope, index) end,
        while_parked: fn -> Process.sleep(600) end
      )

    assert {:ok, _invitation} = result
    assert seats_taken(org.id) == 5
  end

  defp expire_in(invitation, milliseconds) do
    Alplus.Repo.query!("UPDATE invitations SET expires_at = $1 WHERE id = $2", [
      DateTime.add(DateTime.utc_now(), milliseconds, :millisecond),
      invitation.id
    ])
  end

  defp invite(org, owner_scope, index) do
    Ash.create(
      Invitation,
      %{
        org_id: org.id,
        email: "seat-#{System.unique_integer([:positive])}-#{index}@example.com",
        role: "member"
      },
      action: :invite,
      actor: owner_scope
    )
  end

  defp create_project(org, owner_scope, index) do
    Ash.create(Project, %{org_id: org.id, name: "Project #{index}"},
      action: :create,
      actor: owner_scope
    )
  end

  defp seats_taken(org_id) do
    query(
      """
      SELECT (SELECT count(*) FROM memberships WHERE org_id = $1)
           + (SELECT count(*) FROM invitations
              WHERE org_id = $1 AND status = 'pending' AND expires_at > now())
      """,
      org_id
    )
  end

  defp active_projects(org_id),
    do: query("SELECT count(*) FROM projects WHERE org_id = $1 AND archived_at IS NULL", org_id)

  defp query(sql, org_id) do
    %{rows: [[count]]} = Alplus.Repo.query!(sql, [org_id])
    count
  end
end
