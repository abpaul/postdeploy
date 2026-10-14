defmodule Alplus.Notifications.ChannelEntitlementTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  test "the public domain create refuses an inactive organization" do
    {org, owner_scope} = org_fixture(scope_fixture())

    Alplus.Repo.query!("UPDATE organizations SET trial_ends_at = $1 WHERE id = $2", [
      ~U[2000-01-01 00:00:00.000000Z],
      org.id
    ])

    assert {:error, %Ash.Error.Invalid{}} =
             Alplus.Notifications.create_channel(
               %{org_id: org.id, type: "email", name: "Operations", config: %{}},
               owner_scope
             )

    assert [[0]] =
             Alplus.Repo.query!("SELECT count(*) FROM notification_channels WHERE org_id = $1", [
               org.id
             ]).rows
  end
end
