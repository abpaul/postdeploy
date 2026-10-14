defmodule AlplusWeb.RegisterLiveTest do
  use AlplusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  require Ash.Query

  alias Alplus.Accounts.User
  alias Alplus.Turnstile

  defp params(overrides \\ %{}) do
    Map.merge(
      %{
        "email" => "new-#{System.unique_integer([:positive])}@example.com",
        "password" => "a-str0ng-passphrase",
        "password_confirmation" => "a-str0ng-passphrase",
        "turnstile_token" => "widget-token"
      },
      overrides
    )
  end

  # The Turnstile token is written into the hidden `#turnstile-token` input
  # by the JS hook's callback, then submitted as part of the normal form
  # payload — never through `form/2`, which locks hidden-input values to
  # what the server rendered (correctly refusing to let a test "tamper"
  # with a hidden field the same way it would refuse for a real client).
  # Dispatching the "save" event directly is the same payload shape a real
  # submit sends once the widget has populated that field.
  test "creates a user when Turnstile passes (ConnCase's default stub)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/register")

    attrs = params()

    html = render_submit(view, "save", %{"user" => attrs})

    assert {:ok, %User{}} = fetch_user_by_email(attrs["email"])

    # Auto-sign-in after registration renders a same-origin form carrying the
    # register action's sign-in JWT, which a browser submits over HTTP. An
    # unverified session deliberately lands on the dashboard verification gate,
    # not the organization-creation route.
    token = extract_auto_signin_token(html)
    conn = post(conn, ~p"/register/complete", %{"token" => token})

    assert redirected_to(conn) == ~p"/dashboard"
    {:ok, dashboard_view, _html} = live(conn, ~p"/dashboard")
    assert has_element?(dashboard_view, "#activation-email-verification")
    assert {:ok, %User{id: user_id}} = fetch_user_by_email(attrs["email"])
    assert conn.assigns.current_user.id == user_id
  end

  # Security regression: `/register/complete` must accept only a real session
  # token (`"purpose" => "user"`). A validly-signed password-reset or
  # confirmation token for the same user carries a different purpose; without
  # the guard, POSTing one here would mint a full session — account takeover
  # via a leaked reset link.
  test "rejects a validly-signed token whose purpose is not \"user\"", %{conn: conn} do
    user = Alplus.OrgsFixtures.user_fixture()

    {:ok, wrong_token, _claims} =
      AshAuthentication.Jwt.token_for_user(user, %{"purpose" => "password_reset"})

    conn = post(conn, ~p"/register/complete", %{"token" => wrong_token})

    assert redirected_to(conn) == ~p"/sign-in"
    refute conn.assigns[:current_user]
  end

  test "does not create a user when Turnstile verification fails", %{conn: conn} do
    Req.Test.stub(Turnstile.Client, fn conn -> Req.Test.json(conn, %{"success" => false}) end)

    {:ok, view, _html} = live(conn, ~p"/register")

    attrs = params()

    html = render_submit(view, "save", %{"user" => attrs})

    assert html =~ "Verification failed"

    assert {:ok, nil} = fetch_user_by_email(attrs["email"])
  end

  # Regression: a Turnstile token is single-use. Cloudflare's siteverify
  # returns success on the first check and "timeout-or-duplicate" on any
  # repeat. The widget's JS callback fills `#turnstile-token` via an
  # `input` event, which fires `phx-change="validate"` before the real
  # `save` submit. If verification runs as an Ash validation (which fires
  # on both `validate` and `save`), the `validate` call spends the token
  # and `save` always sees a stale one. This test drives that exact
  # sequence — validate, then save — and asserts siteverify is hit once.
  test "creates a user when the widget's phx-change validate fires before save",
       %{conn: conn} do
    # :counters is a lock-free erlang term, not a process — no supervision
    # concern, unlike an Agent, for this test-local single-use call count.
    counter = :counters.new(1, [])

    Req.Test.stub(Turnstile.Client, fn conn ->
      call = :counters.get(counter, 1) + 1
      :counters.add(counter, 1, 1)

      if call == 1 do
        Req.Test.json(conn, %{"success" => true})
      else
        Req.Test.json(conn, %{"success" => false, "error-codes" => ["timeout-or-duplicate"]})
      end
    end)

    {:ok, view, _html} = live(conn, ~p"/register")

    attrs = params()

    # Simulates the widget callback: it sets #turnstile-token then
    # dispatches an `input` event, which the form wires to phx-change.
    render_change(view, "validate", %{"user" => attrs})

    html = render_submit(view, "save", %{"user" => attrs})

    refute html =~ "Verification failed"
    assert {:ok, %User{}} = fetch_user_by_email(attrs["email"])
    assert :counters.get(counter, 1) == 1
  end

  test "renders the Turnstile widget container with the configured site key", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/register")

    assert html =~ ~s(id="turnstile-widget")
    assert html =~ Application.fetch_env!(:alplus, :turnstile_site_key)
    assert has_element?(view, "#turnstile-token")
  end

  test "renders a keyboard-focusable retry control for Turnstile load failures", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/register")

    assert has_element?(
             view,
             ~s(button#turnstile-retry[type="button"][hidden]),
             "Retry security check"
           )

    assert html =~ "Security check could not load. Use the retry button to try again."
  end

  defp extract_auto_signin_token(html) do
    [_, token] = Regex.run(~r{name="token" value="([^"]+)"}, html)
    token
  end

  defp fetch_user_by_email(email) do
    User
    |> Ash.Query.filter(email == ^email)
    |> Ash.read_one(authorize?: false)
  end
end
