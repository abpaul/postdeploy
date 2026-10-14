defmodule AlplusWeb.AuthPageTitle do
  @moduledoc """
  Sets `:page_title`, the visible `:heading`, `:page_subtitle`, and (sign-in
  only) the header `:cross_link_*` triplet for the three signed-out screens
  `AshAuthentication.Phoenix` owns (sign-in, reset, confirm). Their
  `SignInLive`/`ResetLive`/`ConfirmLive` never assign these themselves, so
  without this hook the browser tab fell back to the root layout's default
  ("PostDeploy") and `Layouts.auth_live/1` had nothing to put in its `h1`.
  `RegisterLive`/`OrgCreateLive`/`InvitationAcceptLive` set their own
  `:page_title` in `mount/3` instead, since they call `Layouts.auth/1`
  directly rather than through this on_mount hook.

  `:heading` carries the mock's display voice ("Welcome back."); `:page_title`
  stays the plainer browser-tab text — the two are allowed to differ.

  A separate module from `AlplusWeb.LiveUserAuth` on purpose:
  `AshAuthentication.Phoenix.Router`'s route macros dedupe their `on_mount:`
  list with `Enum.uniq_by(fn {mod, _} -> mod; mod -> mod end)` — keyed on the
  *module* only, not the `{module, function}` pair. Adding a second
  `{AlplusWeb.LiveUserAuth, ...}` hook next to the existing `:live_no_user`
  one would have silently dropped whichever came second.

  `/reset` (request a reset link) is *not* a separate LiveView — it's
  `AshAuthentication.Phoenix.SignInLive`'s own `:reset` `live_action`,
  configured via `sign_in_route`'s `reset_path:` option and sharing that
  route's single `{AlplusWeb.AuthPageTitle, :sign_in}` on_mount hook (both
  `/sign-in` and `/reset` sit in the same `auth_sign_in` live_session — see
  `mix phx.routes`). The `on_mount(:sign_in, ...)` clause below branches on
  `socket.assigns.live_action`, which the router assigns before on_mount
  hooks run, to give the two states their own heading instead of both
  showing "Welcome back." The *separate* `AshAuthentication.Phoenix.ResetLive`
  (the "set a new password" form after the emailed link) lives at
  `/password-reset/:token` and uses the `on_mount(:reset, ...)` clause via
  its own `reset_route` on_mount list.
  """

  import Phoenix.Component, only: [assign: 3]

  def on_mount(:sign_in, _params, _session, %{assigns: %{live_action: :reset}} = socket) do
    {:cont,
     socket
     |> assign(:page_title, "Reset your password")
     |> assign(:heading, "Reset your password.")
     |> assign(:page_subtitle, "We'll email you a link to set a new one.")}
  end

  def on_mount(:sign_in, _params, _session, socket) do
    {:cont,
     socket
     |> assign(:page_title, "Sign in")
     |> assign(:heading, "Welcome back.")
     |> assign(:page_subtitle, "Pick up right where you left off.")
     |> assign(:cross_link_lead, "New here?")
     |> assign(:cross_link_label, "Create an account")
     |> assign(:cross_link_path, "/register")}
  end

  def on_mount(:reset, _params, _session, socket) do
    {:cont,
     socket
     |> assign(:page_title, "Reset your password")
     |> assign(:heading, "Reset your password.")
     |> assign(:page_subtitle, "We'll email you a link to set a new one.")}
  end

  def on_mount(:confirm_new_user, _params, _session, socket) do
    {:cont,
     socket
     |> assign(:page_title, "Confirm your account")
     |> assign(:heading, "Confirm your account.")
     |> assign(:page_subtitle, "One more step before you can sign in.")}
  end

  def on_mount(:confirm_email_change, _params, _session, socket) do
    {:cont,
     socket
     |> assign(:page_title, "Confirm your new email")
     |> assign(:heading, "Confirm your new email.")
     |> assign(:page_subtitle, "This keeps your account details up to date.")}
  end
end
