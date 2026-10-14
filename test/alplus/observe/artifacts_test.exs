defmodule Alplus.Observe.ArtifactsTest do
  use ExUnit.Case, async: true

  alias Alplus.Observe.Artifacts

  test "rejects unsafe artifact names before storage" do
    source = %{id: "src_1", org_id: "org_1", project_id: "proj_1", environment: "production"}
    raw = ~s({"version":3,"mappings":"","sources":[]})

    assert {:error, :invalid_params} = Artifacts.ingest(source, "1.0.0", "../app.js.map", raw)
    assert {:error, :invalid_params} = Artifacts.ingest(source, "", "app.js.map", raw)
  end

  test "rejects non-v3 source maps before storage" do
    source = %{id: "src_1", org_id: "org_1", project_id: "proj_1", environment: "production"}

    assert {:error, :invalid_source_map} =
             Artifacts.ingest(source, "1.0.0", "app.js.map", ~s({"version":2}))
  end
end
