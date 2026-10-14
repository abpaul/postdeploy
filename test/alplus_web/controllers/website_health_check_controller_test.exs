defmodule AlplusWeb.WebsiteHealthCheckControllerTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Growth.HealthCheck
  alias AlplusWeb.WebsiteHealthCheck.Handoff

  setup do
    Alplus.Content.Seeds.run()
    :ok
  end

  test "the monitor handoff stores the draft and sends anonymous visitors to register",
       %{conn: conn} do
    journey_id = HealthCheck.new_journey_id()

    conn =
      post(conn, ~p"/tools/website-health-check/monitor", %{
        "target_url" => "example.com",
        "keyword" => "healthy",
        "journey_id" => journey_id
      })

    assert redirected_to(conn) == ~p"/register"
    assert Plug.Conn.get_session(conn, :return_to) == Handoff.continue_path()
    assert {:ok, %{url: "https://example.com/", keyword: "healthy"}} = Handoff.peek(conn)
    assert Plug.Conn.get_session(conn, "health_check_journey_id") == journey_id
  end

  test "the monitor handoff rejects an address it cannot check", %{conn: conn} do
    conn = post(conn, ~p"/tools/website-health-check/monitor", %{"target_url" => "ftp://x.test/"})

    assert redirected_to(conn) == "/tools/website-health-check"
    assert Handoff.peek(conn) == :missing
  end

  test "a forged journey id is not stored", %{conn: conn} do
    conn =
      post(conn, ~p"/tools/website-health-check/monitor", %{
        "target_url" => "example.com",
        "journey_id" => "not a journey id"
      })

    assert redirected_to(conn) == ~p"/register"
    refute Plug.Conn.get_session(conn, "health_check_journey_id")
  end

  test "confirmation creates a monitor, shows the first check, and continues the journey",
       %{conn: conn} do
    user = user_fixture()
    {org, scope} = org_fixture(scope_fixture(%{user: user}))
    project = project_fixture(scope, org)
    journey_id = HealthCheck.new_journey_id()

    Application.put_env(:alplus, :monitor_check_opts,
      request: fn _ -> {:ok, %{status: 200, body: "ok"}} end
    )

    on_exit(fn -> Application.delete_env(:alplus, :monitor_check_opts) end)

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(user)
      |> post(~p"/tools/website-health-check/monitor", %{
        "target_url" => "https://example.com/",
        "keyword" => "",
        "journey_id" => journey_id
      })
      |> recycle()
      |> get(~p"/tools/website-health-check/continue")

    html = html_response(conn, 200)
    assert html =~ "https://example.com/"
    assert html =~ ~s(id="health-check-confirm-form")

    conn = conn |> recycle() |> post(~p"/tools/website-health-check/continue")
    html = html_response(conn, 200)
    assert html =~ "Monitor created"
    assert html =~ ~s(id="health-check-first-check")
    assert Handoff.peek(conn) == :missing

    stages = journey_stages(journey_id)
    assert "configured" in stages
    assert "activated" in stages
    _ = {org, project}
  end

  test "an expired draft is rejected", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(%{
        "health_check_draft" => %{
          "url" => "https://example.com/",
          "keyword" => nil,
          "created_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -25, :hour))
        }
      })
      |> get(~p"/tools/website-health-check/continue")

    assert redirected_to(conn) == "/tools/website-health-check"
  end

  test "the sitemap lists the canonical tool URL and no handoff step", %{conn: conn} do
    body = get(conn, ~p"/sitemap.xml").resp_body

    assert body =~ "<loc>https://postdeploy.dev/tools/website-health-check</loc>"
    refute body =~ "/tools/website-health-check/continue"
  end

  test "the uptime page links to the tool", %{conn: conn} do
    html = html_response(get(conn, ~p"/monitoring/uptime"), 200)
    assert html =~ ~s(href="/tools/website-health-check")
  end

  test "the footer links to the tool from every public page", %{conn: conn} do
    html = html_response(get(conn, ~p"/monitoring"), 200)
    assert html =~ ~s(href="/tools/website-health-check")
  end

  test "the handed-off address never reaches the logs or the query string", %{conn: conn} do
    target = "https://example.com/secret-path"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        conn =
          post(conn, ~p"/tools/website-health-check/monitor?keep=1", %{"target_url" => target})

        assert conn.query_string == ""
        assert redirected_to(conn) == ~p"/register"
      end)

    refute log =~ "secret-path"

    {:ok, events} = Alplus.Growth.list_journey_events(authorize?: false)
    refute Enum.any?(events, fn event -> inspect(event) =~ "secret-path" end)
  end

  defp journey_stages(journey_id) do
    {:ok, rows} = Alplus.Growth.list_journey_events(authorize?: false)

    rows
    |> Enum.filter(&(&1.journey_id == journey_id))
    |> Enum.map(& &1.stage)
  end
end
