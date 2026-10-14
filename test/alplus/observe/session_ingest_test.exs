defmodule Alplus.Observe.SessionIngestTest do
  use ExUnit.Case, async: true

  alias Alplus.Observe.SessionIngest

  test "returns malformed counts without touching persistence for an empty parsed batch" do
    source = %{id: "src_1", org_id: "org_1", project_id: "proj_1", environment: "production"}

    assert %{accepted: 0, dropped: 2, dropped_reason: "malformed"} =
             SessionIngest.write(%{items: []}, %{
               source: source,
               environment: "production",
               malformed: 2
             })
  end
end
