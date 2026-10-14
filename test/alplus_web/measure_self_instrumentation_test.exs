defmodule AlplusWeb.MeasureSelfInstrumentationTest do
  @moduledoc """
  We instrument our own marketing pages with our own Measure snippet
  (dogfooding). Three properties matter to a visitor and to our analytics
  data, and all three are invisible without a test: the snippet appears on
  marketing pages, it never appears on the console (whose URLs carry customer
  org and project tokens), and it disappears entirely when no token is
  configured, so a developer machine cannot beacon into production.
  """
  use AlplusWeb.ConnCase, async: false

  @token "msr_test_token_not_real"

  setup do
    Alplus.Content.Seeds.run()
    previous = Application.get_env(:alplus, :measure_self_token)
    Application.put_env(:alplus, :measure_self_token, @token)
    on_exit(fn -> Application.put_env(:alplus, :measure_self_token, previous) end)
    :ok
  end

  test "home and pricing load the snippet from a relative src", %{conn: conn} do
    for path <- [~p"/", ~p"/pricing"] do
      html = conn |> get(path) |> html_response(200)

      assert html =~ ~s(src="/m.js?token=#{@token}")
      # Relative, not absolute: `m.js` derives its ingest endpoint from its own
      # src, and an absolute origin would be cross-origin under our CSP.
      refute html =~ "https://postdeploy.dev/m.js"
    end
  end

  test "no token configured renders no snippet at all", %{conn: conn} do
    Application.put_env(:alplus, :measure_self_token, nil)

    html = conn |> get(~p"/pricing") |> html_response(200)

    refute html =~ "/m.js"
  end

  test "the console is not instrumented", %{conn: conn} do
    html = conn |> get(~p"/sign-in") |> html_response(200)

    refute html =~ "/m.js"
  end
end
