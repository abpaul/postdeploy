defmodule Alplus.Billing.UsageRolloverTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Billing.UsageRollover
  alias Alplus.Repo

  test "creates one empty period per organization and is idempotent" do
    owner = scope_fixture()
    {first_org, _scope} = org_fixture(owner)
    {second_org, _scope} = org_fixture(scope_fixture())
    date = ~D[2026-09-12]

    assert 2 == UsageRollover.rollover(date)
    assert 0 == UsageRollover.rollover(date)

    assert %{rows: [[2]]} =
             Repo.query!(
               "SELECT count(*) FROM usage_periods WHERE period_start = $1 AND org_id IN ($2, $3)",
               [~D[2026-09-01], first_org.id, second_org.id]
             )
  end
end
