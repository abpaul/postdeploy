defmodule Alplus.GrowthAttributionTest do
  @moduledoc """
  Organic acquisition attribution, end to end.

  The valuable assertion is the whole journey: a visitor lands on a guide
  from a search engine, registers, and the resulting row credits the guide
  rather than `/register`. Testing the plug in isolation would not catch a
  broken pipeline or a session that never survives to the controller.
  """

  use AlplusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  require Ash.Query

  alias Alplus.Growth
  alias Alplus.Growth.SignupAttribution

  setup do
    Alplus.Content.Seeds.run()
    :ok
  end

  defp attribution_for(user_id) do
    SignupAttribution
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp register(conn, email) do
    {:ok, view, _html} = live(conn, ~p"/register")

    html =
      render_submit(view, "save", %{
        "user" => %{
          "email" => email,
          "password" => "a-str0ng-passphrase",
          "password_confirmation" => "a-str0ng-passphrase",
          "turnstile_token" => "widget-token"
        }
      })

    token = extract_token(html)
    post(conn, ~p"/register/complete", %{"token" => token})
  end

  # Matches the extraction in `AlplusWeb.RegisterLiveTest`: the auto-submit
  # form carries the register action's sign-in JWT in a hidden input.
  defp extract_token(html) do
    [_, token] = Regex.run(~r{name="token" value="([^"]+)"}, html)
    token
  end

  describe "a full organic journey" do
    test "credits the landing page a visitor actually arrived on", %{conn: conn} do
      email = "organic-#{System.unique_integer([:positive])}@example.com"

      conn =
        conn
        # Arrive from Google on a guide, the way an organic visitor does.
        |> put_req_header(
          "referer",
          "https://www.google.com/search?q=kubernetes+cronjob+monitoring"
        )
        |> get(~p"/guides/kubernetes-cronjob-heartbeat")

      # Browse on to the hub, then to the form. First touch must win.
      conn = conn |> recycle() |> get(~p"/monitoring")

      conn = register(recycle(conn), email)

      assert conn.assigns.current_user
      attribution = attribution_for(conn.assigns.current_user.id)

      assert attribution.landing_page == "/guides/kubernetes-cronjob-heartbeat"
      assert attribution.referrer_host == "www.google.com"
      assert attribution.content_cluster == "cron"
    end

    test "records UTM tags from the landing URL", %{conn: conn} do
      email = "utm-#{System.unique_integer([:positive])}@example.com"

      conn =
        get(conn, "/monitoring/cron-jobs?utm_source=reddit&utm_medium=social&utm_campaign=devops")

      conn = register(recycle(conn), email)
      attribution = attribution_for(conn.assigns.current_user.id)

      assert attribution.utm == %{
               "utm_source" => "reddit",
               "utm_medium" => "social",
               "utm_campaign" => "devops"
             }

      assert attribution.content_cluster == "cron"
    end

    test "a visitor who lands straight on /register is recorded as direct", %{conn: conn} do
      email = "direct-#{System.unique_integer([:positive])}@example.com"

      conn = register(conn, email)
      attribution = attribution_for(conn.assigns.current_user.id)

      # Recorded rather than skipped, so the organic share of signups is a
      # proportion of every signup rather than of an unknown total.
      assert attribution.landing_page == "/register"
      assert attribution.referrer_host == nil
      assert attribution.content_cluster == "direct"
    end
  end

  describe "privacy" do
    test "stores only the referrer host, never the full referring URL", %{conn: conn} do
      email = "priv-#{System.unique_integer([:positive])}@example.com"

      conn =
        conn
        |> put_req_header("referer", "https://duckduckgo.com/?q=secret+search+terms&ia=web")
        |> get(~p"/monitoring")

      conn = register(recycle(conn), email)
      attribution = attribution_for(conn.assigns.current_user.id)

      assert attribution.referrer_host == "duckduckgo.com"
      # The searcher's query is theirs, and must not reach our database.
      refute attribution.referrer_host =~ "secret"
    end

    test "records no IP address or user agent", %{conn: conn} do
      email = "noip-#{System.unique_integer([:positive])}@example.com"

      conn =
        conn
        |> put_req_header("user-agent", "Mozilla/5.0 (very identifying)")
        |> get(~p"/monitoring")

      conn = register(recycle(conn), email)
      attribution = attribution_for(conn.assigns.current_user.id)

      recorded = attribution |> Map.from_struct() |> inspect()

      refute recorded =~ "Mozilla"
      refute recorded =~ "127.0.0.1"
    end

    test "an unauthorized read returns no acquisition rows", %{conn: conn} do
      email = "leak-#{System.unique_integer([:positive])}@example.com"
      conn = conn |> get(~p"/monitoring") |> recycle() |> register(email)

      # The row exists.
      assert attribution_for(conn.assigns.current_user.id)

      # Reporting data is staff-only. Consistent with the tenancy rule in
      # AGENTS.md, an unauthorized read filters the rows away rather than
      # returning 403, so nothing leaks either way.
      assert {:ok, []} = Ash.read(SignupAttribution, actor: nil)
      assert {:ok, []} = Ash.read(SignupAttribution, actor: %{id: "user_someone_else"})
    end
  end

  describe "content clusters" do
    test "map each landing path to its reporting cluster" do
      assert Growth.content_cluster("/monitoring/cron-jobs") == "cron"
      assert Growth.content_cluster("/guides/github-actions-heartbeat") == "cron"
      assert Growth.content_cluster("/monitoring/uptime") == "uptime"
      assert Growth.content_cluster("/tools/website-health-check") == "uptime"
      assert Growth.content_cluster("/monitoring/api") == "api"
      assert Growth.content_cluster("/alternatives/cronitor") == "comparison"
      assert Growth.content_cluster("/pricing") == "pricing"
      assert Growth.content_cluster("/nothing-here") == "other"
    end
  end

  describe "failure handling" do
    test "a signup is never broken by unrecordable attribution" do
      # Acquisition reporting is not worth a lost customer, so a bad payload
      # returns :ok rather than raising into the registration request.
      assert :ok = Growth.record_signup_attribution("user_does_not_exist", nil)
      assert :ok = Growth.record_signup_attribution("user_does_not_exist", "not a map")

      assert :ok =
               Growth.record_signup_attribution("user_x", %{
                 "landing_page" => String.duplicate("x", 5_000)
               })
    end
  end

  describe "growth targets" do
    test "come from one configurable source" do
      targets = Growth.targets()

      assert targets.organic_signup_conversion_rate == 0.05
      assert targets.signup_to_activation_rate == 0.35
      assert targets.organic_visits == 2_000
    end
  end
end
