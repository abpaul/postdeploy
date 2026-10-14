defmodule AlplusWeb.LiveUserAuth do
  @moduledoc """
  Helpers for authenticating users in LiveViews.
  """

  import Phoenix.Component
  use AlplusWeb, :verified_routes

  # This is used for nested liveviews to fetch the current user.
  # To use, place the following at the top of that liveview:
  # on_mount {AlplusWeb.LiveUserAuth, :current_user}
  def on_mount(:current_user, _params, session, socket) do
    {:cont, AshAuthentication.Phoenix.LiveSession.assign_new_resources(socket, session)}
  end

  def on_mount(:live_user_optional, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end

  # Onboarding overhaul decision #1 (docs/research/onboarding-best-practices
  # -2026-08-13.md): the dashboard is usable before email confirmation,
  # because gating it drops 10-30% of signups before they see any value.
  # `AlplusWeb.ConfirmEmailBanner` nudges an unconfirmed user from inside
  # the shell instead; only invite-sending (`AlplusWeb.TeamLive`) still
  # checks `confirmed_at` directly. A session with no user at all still
  # bounces to sign-in — this mount still requires *a* session, just not a
  # confirmed one.
  def on_mount(:live_user_required, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  # A signed-in visitor who opens /sign-in or /register belongs in the
  # console, not back on the marketing homepage. The marketing CTAs already
  # link straight to /dashboard for them (`MarketingComponents.start_path/1`);
  # this covers a bookmark, a stale tab, and the back button.
  def on_mount(:live_no_user, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/dashboard")}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end
end
