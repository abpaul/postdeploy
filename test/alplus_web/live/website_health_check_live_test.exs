defmodule AlplusWeb.WebsiteHealthCheckLiveTest do
  use AlplusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Alplus.Monitoring.AnonymousProbe.RateLimiter

  @public {93, 184, 216, 34}

  setup do
    Alplus.Content.Seeds.run()
    previous = Application.get_env(:alplus, :anonymous_probe_opts, [])

    Application.put_env(:alplus, :anonymous_probe_opts,
      resolver: fn "example.com" -> {:ok, [@public]} end,
      request: fn _opts ->
        {:ok,
         %{
           status: 200,
           headers: [{"server", "cloudflare"}, {"strict-transport-security", "max-age=63072000"}],
           body: "Status: healthy"
         }}
      end,
      tls: fn _host, _address, _port, _timeout ->
        {:ok, %{trusted: true, expires_at: DateTime.add(DateTime.utc_now(), 40, :day)}}
      end
    )

    on_exit(fn -> Application.put_env(:alplus, :anonymous_probe_opts, previous) end)
    :ok
  end

  test "the dead render carries the indexable form and page metadata", %{conn: conn} do
    conn = get(conn, ~p"/tools/website-health-check")
    html = html_response(conn, 200)

    assert html =~ ~r/<title[^>]*>Website health check \| PostDeploy<\/title>/
    assert html =~ ~s(rel="canonical" href="https://postdeploy.dev/tools/website-health-check")
    assert html =~ "<h1"
    assert html =~ ~s(id="website-health-check-form")
    assert html =~ ~s(for="health-check-url")
    assert html =~ ~s(for="health-check-keyword")
    assert html =~ ~s(aria-label="Breadcrumb")
    assert html =~ ~s(href="/monitoring/uptime")
    refute html =~ ~s(name="robots")
  end

  test "a check runs over the socket and answers in place", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/tools/website-health-check")

    live
    |> check_form(%{
      "target_url" => "https://example.com/",
      "keyword" => "healthy",
      "turnstile_token" => "test-token"
    })
    |> render_submit(%{"turnstile_token" => "test-token"})

    html = render_async(live)

    assert html =~ "Responded"
    assert html =~ "200"
    assert html =~ "cloudflare"
    assert html =~ "max-age=63072000"
    assert html =~ "Monitor this site continuously"
    # The fetched body is reported on, never rendered.
    refute html =~ "Status: healthy"

    assert has_element?(live, "#health-check-monitor-form input[value='https://example.com/']")
  end

  test "a bare domain is checked over HTTPS", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/tools/website-health-check")

    live
    |> check_form(%{
      "target_url" => "example.com",
      "keyword" => "",
      "turnstile_token" => "test-token"
    })
    |> render_submit(%{"turnstile_token" => "test-token"})

    assert render_async(live) =~ "https://example.com/"
  end

  test "a rejected address keeps the form and names the problem", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/tools/website-health-check")

    html =
      live
      |> check_form(%{
        "target_url" => "ftp://example.com/",
        "keyword" => "",
        "turnstile_token" => "test-token"
      })
      |> render_submit(%{"turnstile_token" => "test-token"})

    assert html =~ "Enter an http:// or https:// URL."
    assert has_element?(live, "#website-health-check-form")
    refute has_element?(live, "#health-check-result")
  end

  test "the rate limit is reported on the form, not as a result", %{conn: conn} do
    previous = Application.get_env(:alplus, RateLimiter, [])
    Application.put_env(:alplus, RateLimiter, ip_limit: 1, global_limit: 1, window_ms: 60_000)
    on_exit(fn -> Application.put_env(:alplus, RateLimiter, previous) end)

    {:ok, live, _html} = live(conn, ~p"/tools/website-health-check")

    params = %{
      "target_url" => "https://example.com/",
      "keyword" => "",
      "turnstile_token" => "test-token"
    }

    live |> check_form(params) |> render_submit(%{"turnstile_token" => "test-token"})
    _ = render_async(live)

    html = live |> check_form(params) |> render_submit(%{"turnstile_token" => "test-token"})

    assert html =~ "Too many checks right now."
  end

  test "checking another address returns to the empty form", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/tools/website-health-check")

    live
    |> check_form(%{
      "target_url" => "example.com",
      "keyword" => "",
      "turnstile_token" => "test-token"
    })
    |> render_submit(%{"turnstile_token" => "test-token"})

    _ = render_async(live)
    assert has_element?(live, "#health-check-result")

    live |> element("#health-check-convert button[phx-click='reset']") |> render_click()

    refute has_element?(live, "#health-check-result")
    assert has_element?(live, "#health-check-expect")
  end

  test "the two funnel stages are recorded against one journey", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/tools/website-health-check")

    live
    |> check_form(%{
      "target_url" => "example.com",
      "keyword" => "",
      "turnstile_token" => "test-token"
    })
    |> render_submit(%{"turnstile_token" => "test-token"})

    _ = render_async(live)

    journey_id =
      live
      |> element("#health-check-monitor-form input[name='journey_id']")
      |> render()
      |> then(&Regex.run(~r/value="([^"]+)"/, &1))
      |> Enum.at(1)

    {:ok, rows} = Alplus.Growth.list_journey_events(authorize?: false)
    stages = rows |> Enum.filter(&(&1.journey_id == journey_id)) |> Enum.map(& &1.stage)

    assert "health_check_started" in stages
    assert "health_check_result_produced" in stages
  end

  test "a reflected keyword is escaped", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/tools/website-health-check")

    live
    |> check_form(%{
      "target_url" => "https://example.com/",
      "keyword" => "<script>alert(1)</script>",
      "turnstile_token" => "test-token"
    })
    |> render_submit(%{"turnstile_token" => "test-token"})

    html = render_async(live)

    refute html =~ "<script>alert(1)</script>"
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
  end

  test "failed, missing, and unavailable challenges do not run a probe", %{conn: conn} do
    Application.put_env(:alplus, :anonymous_probe_opts,
      resolver: fn _ -> flunk("A rejected challenge must not resolve the target") end,
      request: fn _ -> flunk("A rejected challenge must not contact the target") end
    )

    for {token, response} <- [
          {nil, :denied},
          {"invalid-token", :denied},
          {"unavailable-token", :unavailable},
          {%{"token" => "bad"}, :denied}
        ] do
      Req.Test.stub(Alplus.Turnstile.Client, fn request ->
        case response do
          :denied -> Req.Test.json(request, %{"success" => false})
          :unavailable -> Req.Test.transport_error(request, :timeout)
        end
      end)

      {:ok, view, _html} = live(conn, "/tools/website-health-check")

      render_submit(view, "check", %{
        "target_url" => "https://example.com",
        "turnstile_token" => token
      })

      assert render(view) =~ "Complete the security check and try again."
    end

    assert {:ok, []} = Alplus.Growth.list_journey_events(authorize?: false)
  end

  defp check_form(view, params) do
    form(view, "#website-health-check-form", Map.delete(params, "turnstile_token"))
  end
end
