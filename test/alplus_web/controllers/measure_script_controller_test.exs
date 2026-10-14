defmodule AlplusWeb.MeasureScriptControllerTest do
  use AlplusWeb.ConnCase, async: true

  import Alplus.OrgsFixtures

  @runtime_fixture Path.expand("../../fixtures/measure_script_runtime.mjs", __DIR__)
  @external_resource @runtime_fixture

  test "serves a compact cacheable DNT-aware tracker", %{conn: conn} do
    conn = get(conn, "/m.js")

    assert response(conn, 200) =~ "pageshow"
    assert response(conn, 200) =~ "doNotTrack"
    assert response(conn, 200) =~ "popstate"
    assert response(conn, 200) =~ "hashchange"
    assert response(conn, 200) =~ "pushState"
    assert byte_size(:zlib.gzip(response(conn, 200))) < 2_500

    assert get_resp_header(conn, "cache-control") == [
             "public, max-age=3600, stale-while-revalidate=86400"
           ]
  end

  test "both Measure globals share one tracker without duplicate delivery", %{conn: conn} do
    body = response(get(conn, "/m.js"), 200)

    node =
      System.find_executable("node") || flunk("node is required for the tracker runtime fixture")

    {output, 0} =
      System.cmd(node, [@runtime_fixture, Base.encode64(body)], stderr_to_stdout: true)

    result = Jason.decode!(output)
    accepted = result["accepted"]
    requests = accepted["requests"]

    assert result["globals"] == %{"canonical" => true, "compatibility" => true}

    assert accepted["counts"] == %{
             "beaconCalls" => 10,
             "fetchCalls" => 0,
             "listeners" => %{"hashchange" => 1, "pageshow" => 1, "popstate" => 1}
           }

    assert Enum.count(requests, &(&1["body"]["type"] == "pageview")) == 7
    assert Enum.count(requests, &(&1["body"]["type"] == "event")) == 3
    assert Enum.count(requests, &(&1["body"]["name"] == "canonical")) == 1
    assert Enum.count(requests, &(&1["body"]["name"] == "compatibility")) == 1

    assert result["separateQueues"]["counts"]["beaconCalls"] == 3

    assert Enum.count(
             result["separateQueues"]["requests"],
             &(&1["body"]["name"] == "canonical-preloaded")
           ) == 1

    assert Enum.count(
             result["separateQueues"]["requests"],
             &(&1["body"]["name"] == "compatibility-preloaded")
           ) == 1

    for tracker <- [result["canonicalTracker"], result["legacyTracker"]] do
      assert tracker["aliases"]
      assert tracker["counts"] == %{"beaconCalls" => 0, "fetchCalls" => 0, "listeners" => %{}}
    end

    assert result["canonicalTracker"]["events"] == [["event", "legacy-queued"]]
    assert result["legacyTracker"]["events"] == [["event", "canonical-queued"]]

    assert Enum.all?(requests, &(&1["url"] == "https://ingest.postdeploy.dev/m"))
    assert Enum.all?(requests, &(&1["body"]["referrer"] == "google.com"))
    assert Enum.all?(requests, &(URI.parse(&1["body"]["url"]).query == nil))
    assert Enum.all?(requests, &(URI.parse(&1["body"]["url"]).fragment == nil))

    assert result["rejected"]["beaconCalls"] == 1
    assert result["rejected"]["fetchCalls"] == 1
    assert result["unhandled"] == []
  end

  test "posts to an absolute endpoint from the script origin, not a relative /m", %{conn: conn} do
    body = response(get(conn, "/m.js"), 200)

    # A third-party site embedding the production m.js must POST back to the
    # production host, not to its own origin (which 405s). The beacon derives
    # the endpoint from the script's own src.
    assert body =~ "new URL(C.src).origin"
    assert body =~ "sendBeacon(E"
    assert body =~ "fetch(E"
    refute body =~ ~s|sendBeacon("/m"|
    refute body =~ ~s|fetch("/m"|
  end

  test "a resolved measure token embeds itself as the literal site value", %{conn: conn} do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    {_source, token} = source_fixture(owner_scope, org, project, %{type: :measure})

    conn = get(conn, "/m.js?token=#{token}&v=20260910")

    body = response(conn, 200)
    assert body =~ "site=#{Jason.encode!(token)}"
    refute body =~ "dataset.site"

    assert get_resp_header(conn, "cache-control") == [
             "public, max-age=3600, stale-while-revalidate=86400"
           ]
  end

  test "an unknown or revoked measure token returns 404", %{conn: conn} do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    {source, token} = source_fixture(owner_scope, org, project, %{type: :measure})
    scope = Alplus.Scope.put_project(owner_scope, project.id)

    unknown = get(conn, "/m.js?token=msr_00000000000000000000000000")
    assert unknown.status == 404

    Ash.update!(source, %{}, action: :revoke, actor: scope)
    revoked = get(build_conn(), "/m.js?token=#{token}")
    assert revoked.status == 404
  end
end
