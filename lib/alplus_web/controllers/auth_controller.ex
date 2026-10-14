defmodule AlplusWeb.AuthController do
  use AlplusWeb, :controller
  use AshAuthentication.Phoenix.Controller

  def success(conn, {:password, :sign_in} = activity, user, token) do
    clear_login_lockout(conn)
    do_success(conn, activity, user, token)
  end

  def success(conn, activity, user, token), do: do_success(conn, activity, user, token)

  # Auto-sign-in after `/register` (onboarding overhaul): `RegisterLive`
  # already created the user via `Alplus.Accounts.User`'s
  # `:register_with_password` action directly (for the Turnstile token),
  # so this exchanges the very same sign-in JWT that action's
  # `AshAuthentication.GenerateTokenChange` minted for it, the way
  # `AshAuthentication.Plug.Helpers.store_in_session/2` expects — never a
  # fresh token, never the confirmation token stored separately in
  # `__metadata__.confirmation_token`. Confirmation still happens by email
  # in parallel; this only starts the session, so the user lands in the
  # funnel instead of bouncing to `/sign-in`.
  def complete_registration(conn, %{"token" => token}) do
    # Require `"purpose" => "user"` — the claim a real session token carries
    # (`AshAuthentication.Plug.Helpers` asserts the same on session load).
    # `Jwt.verify/2` only checks signature/expiry/subject, so without this a
    # validly-signed password-reset or confirmation token for the same user
    # (which carry an `"act"` claim, not `"purpose" => "user"`) would mint a
    # full session here — an account takeover via a leaked reset link.
    with {:ok, %{"sub" => subject, "purpose" => "user"}, resource} <-
           AshAuthentication.Jwt.verify(token, :alplus),
         {:ok, user} <- AshAuthentication.subject_to_user(subject, resource) do
      # `subject_to_user/2` returns a plain read — `store_in_session/2`
      # (called by `do_success/4`) needs the verified token itself back on
      # `__metadata__.token`, the same place
      # `AshAuthentication.GenerateTokenChange` leaves it after a normal
      # sign-in.
      user = Ash.Resource.put_metadata(user, :token, token)

      # Acquisition is recorded here rather than in `RegisterLive` because
      # only a real conn can read the session the marketing pipeline wrote.
      # This never raises: see `Alplus.Growth.record_signup_attribution/2`.
      Alplus.Growth.record_signup_attribution(
        user.id,
        get_session(conn, AlplusWeb.Plugs.AcquisitionAttribution.session_key())
      )

      case get_session(conn, "health_check_journey_id") do
        journey_id when is_binary(journey_id) and journey_id != "" ->
          Alplus.Growth.HealthCheck.record(journey_id, "signup", user.id)

        _ ->
          :ok
      end

      do_success(conn, {:password, :register}, user, token)
    else
      _ ->
        conn
        |> put_flash(:error, "Your session could not be started. Please sign in.")
        |> redirect(to: ~p"/sign-in")
    end
  end

  defp do_success(conn, activity, user, _token) do
    return_to = get_session(conn, :return_to) || default_redirect(user)

    message =
      case activity do
        {:confirm_new_user, :confirm} -> "Your email address has now been confirmed"
        {:password, :reset} -> "Your password has successfully been reset"
        {:password, :register} -> "Welcome to PostDeploy. Let's verify your email before setup."
        _ -> "You are now signed in"
      end

    conn
    |> delete_session(:return_to)
    |> store_in_session(user)
    # If your resource has a different name, update the assign name here (i.e :current_admin)
    |> assign(:current_user, user)
    |> put_flash(:info, message)
    |> redirect(to: return_to)
  end

  def failure(conn, {:password, :sign_in} = activity, reason) do
    record_login_lockout_failure(conn)
    do_failure(conn, activity, reason)
  end

  def failure(conn, activity, reason), do: do_failure(conn, activity, reason)

  defp do_failure(conn, activity, reason) do
    message =
      case {activity, reason} do
        {_,
         %AshAuthentication.Errors.AuthenticationFailed{
           caused_by: %Ash.Error.Forbidden{
             errors: [%AshAuthentication.Errors.CannotConfirmUnconfirmedUser{}]
           }
         }} ->
          """
          You have already signed in another way, but have not confirmed your account.
          You can confirm your account using the link we sent to you, or by resetting your password.
          """

        {_,
         %AshAuthentication.Errors.AuthenticationFailed{
           caused_by: %AshAuthentication.Errors.ConfirmationRequired{}
         }} ->
          """
          An account with this email already exists. We've sent a link to that
          address - confirm it to finish linking this provider to your account.
          """

        {{:password, :register}, _} ->
          registration_error_message(reason) || "Registration failed"

        _ ->
          "Email or password is incorrect. Check both, or reset your password."
      end

    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/sign-in")
  end

  # Sends the operator to the first screen that can actually do something.
  #
  # No org: straight to org creation, so the register -> confirm -> org ->
  # project path never dead-ends on a page whose only action is "create an
  # org" one more click away (BUILD.md Phase 2 "Done when").
  #
  # Exactly one org: straight into it. `/dashboard` is the organization
  # picker, and a picker with one option is a click that asks a question the
  # operator has no choice about — the same objection, one step later. The
  # primary user (PRODUCT.md: one operator, one bill) usually has one org, so
  # this is the common path, not an edge case. The picker
  # stays reachable by URL and from the sidebar.
  #
  # Several orgs: the picker, where the choice is real.
  defp default_redirect(%{confirmed_at: nil}), do: ~p"/dashboard"

  defp default_redirect(user) do
    scope = Alplus.Scope.for_user(user.id)

    case Alplus.Orgs.list_organizations(actor: scope) do
      {:ok, []} -> ~p"/dashboard/orgs/new"
      {:ok, [org]} -> ~p"/dashboard/orgs/#{org.public_token}/projects"
      _ -> ~p"/dashboard"
    end
  end

  def sign_out(conn, _params) do
    return_to = get_session(conn, :return_to) || ~p"/"

    conn
    |> clear_session(:alplus)
    |> put_flash(:info, "You are now signed out")
    |> redirect(to: return_to)
  end

  # Login lockout (ARCHITECTURE.md §10, §6): counts by email and by IP,
  # cleared on success. The pre-check that rejects an already-locked
  # identity lives in `AlplusWeb.Router.enforce_login_lockout/2`, which
  # runs before this controller is ever dispatched to.
  defp record_login_lockout_failure(conn) do
    Enum.each(login_lockout_keys(conn), &Alplus.Accounts.LoginLockout.record_failure/1)
  end

  defp clear_login_lockout(conn) do
    Enum.each(login_lockout_keys(conn), &Alplus.Accounts.LoginLockout.clear/1)
  end

  defp login_lockout_keys(conn) do
    ip = AlplusWeb.Router.remote_ip_string(conn)
    email = get_in(conn.params, ["user", "email"])

    [{:ip, ip}] ++ if(is_binary(email), do: [{:email, String.downcase(email)}], else: [])
  end

  # Surfaces our own validation messages (signup gate, password
  # strength, HIBP, Turnstile) verbatim instead of a generic failure,
  # so a disabled signup gate or a rejected password reads clearly.
  defp registration_error_message(%AshAuthentication.Errors.AuthenticationFailed{
         caused_by: caused_by
       }) do
    registration_error_message(caused_by)
  end

  defp registration_error_message(%{errors: errors}) when is_list(errors) and errors != [] do
    errors
    |> Enum.map(&Map.get(&1, :message))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      messages -> Enum.join(messages, " ")
    end
  end

  defp registration_error_message(_reason), do: nil
end
