defmodule Alplus.Measure.DashboardShareTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Measure.DashboardShare
  alias Alplus.Scope

  setup do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)
    {source, _token} = source_fixture(scope, org, project, %{type: :measure})

    %{org: org, project: project, scope: scope, source: source}
  end

  test "an owner creates the default share and resolves its one-time token", context do
    share = create_share!(context)
    token = Ash.Resource.get_metadata(share, :token)

    assert String.starts_with?(token, "shr_")
    assert share.panels == [:headline_cards, :chart, :pages]
    refute Map.has_key?(Map.from_struct(share), :token)

    assert {:ok, resolved, actor} = DashboardShare.resolve(token)
    assert resolved.id == share.id
    assert actor.share_id == share.id
    assert actor.source_id == context.source.id
  end

  test "the token policy rejects a panel that the share does not enable", context do
    share = create_share!(context)
    token = Ash.Resource.get_metadata(share, :token)
    assert {:ok, _share, actor} = DashboardShare.resolve(token)

    input =
      Ash.ActionInput.for_action(
        DashboardShare,
        :public_panel,
        %{
          share_id: share.id,
          org_id: actor.org_id,
          project_id: actor.project_id,
          source_id: actor.source_id,
          environment: actor.environment,
          dimension: :country,
          since: Date.utc_today(),
          until: Date.utc_today(),
          page: 1
        },
        actor: actor,
        domain: Alplus.Measure
      )

    assert {:error, %Ash.Error.Forbidden{}} = Ash.run_action(input)
  end

  test "the panel action binds every capability field at its boundary", context do
    share = create_share!(context)
    token = Ash.Resource.get_metadata(share, :token)
    assert {:ok, _share, actor} = DashboardShare.resolve(token)

    input =
      Ash.ActionInput.for_action(
        DashboardShare,
        :public_panel,
        %{
          share_id: share.id,
          org_id: actor.org_id,
          project_id: "project_forged",
          source_id: actor.source_id,
          environment: actor.environment,
          dimension: :path,
          since: Date.utc_today(),
          until: Date.utc_today(),
          page: 1
        },
        actor: actor,
        domain: Alplus.Measure
      )

    assert {:error, %Ash.Error.Forbidden{}} = Ash.run_action(input)
  end

  test "rotation invalidates the old URL immediately", context do
    share = create_share!(context)
    old_token = Ash.Resource.get_metadata(share, :token)

    rotated = Ash.update!(share, %{}, action: :rotate, actor: context.scope)
    new_token = Ash.Resource.get_metadata(rotated, :token)

    assert {:error, :not_found} = DashboardShare.resolve(old_token)
    assert {:ok, %{id: id}, _actor} = DashboardShare.resolve(new_token)
    assert id == share.id
  end

  test "panels are a closed set", context do
    share = create_share!(context)

    assert {:ok, updated} =
             Ash.update(
               share,
               %{panels: [:headline_cards, :events, :countries]},
               action: :update_panels,
               actor: context.scope
             )

    assert updated.panels == [:headline_cards, :events, :countries]

    assert {:error, _error} =
             Ash.update(
               updated,
               %{panels: [:headline_cards, :secrets]},
               action: :update_panels,
               actor: context.scope
             )
  end

  test "a revoked source makes the public token disappear", context do
    share = create_share!(context)
    token = Ash.Resource.get_metadata(share, :token)
    Ash.update!(context.source, %{}, action: :revoke, actor: context.scope)

    assert {:error, :not_found} = DashboardShare.resolve(token)
  end

  test "an expired plan makes the public token disappear", context do
    share = create_share!(context)
    token = Ash.Resource.get_metadata(share, :token)

    Alplus.Repo.query!("UPDATE organizations SET trial_ends_at = $1 WHERE id = $2", [
      DateTime.add(DateTime.utc_now(), -60, :second),
      context.org.id
    ])

    assert {:error, :not_found} = DashboardShare.resolve(token)
  end

  test "a different tenant cannot read or rotate the share", context do
    share = create_share!(context)
    {_other_org, other_scope} = org_fixture(scope_fixture())

    assert {:error, _error} = Ash.get(DashboardShare, share.id, actor: other_scope)
    assert {:error, _error} = Ash.update(share, %{}, action: :rotate, actor: other_scope)
  end

  defp create_share!(context) do
    Ash.create!(
      DashboardShare,
      %{
        org_id: context.org.id,
        project_id: context.project.id,
        source_id: context.source.id
      },
      actor: context.scope
    )
  end
end
