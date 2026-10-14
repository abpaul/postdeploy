defmodule Alplus.Monitoring.RetentionTest do
  use Alplus.DataCase, async: true

  alias Alplus.Monitoring.Retention
  alias Alplus.Scope

  test "scoped prune deletes nothing for an unknown project" do
    scope = %Scope{org_id: "org_missing", project_id: "proj_missing"}
    result = Retention.prune_monitor_checks(scope, DateTime.utc_now())
    assert result.deleted == 0
    assert %DateTime{} = result.cutoff
  end
end
