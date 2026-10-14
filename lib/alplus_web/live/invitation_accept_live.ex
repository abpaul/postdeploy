defmodule AlplusWeb.InvitationAcceptLive do
  @moduledoc """
  Public accept page for an org invitation, at `/invitations/:token`
  (linked from `Alplus.Orgs.Invitation.Senders.SendInvitationEmail`).

  Unauthenticated by design (ARCHITECTURE.md §4, §10): an invited person
  may have no account yet. `on_mount {AlplusWeb.LiveUserAuth,
  :current_user}` assigns `current_user` (or `nil`) from the session
  without requiring one, unlike `:live_user_required`.

  The invitation is looked up and classified on every mount (not gated by
  `connected?/1`) so the disconnected render already answers 404 for an
  unknown token, matching `AlplusWeb.OrgContext`'s rationale for its own
  unconditional read.

  Round trip through sign-in/register: `AlplusWeb.Router` stashes this
  page's path as the session `return_to` for a signed-out visitor
  (`stash_invitation_return_to/2`), which `AlplusWeb.AuthController`
  already reads after a successful sign-in or confirmation. The token
  never travels through a query string — only through the path, the same
  way the emailed link itself carries it.

  The `:accept` event re-runs every check the read-time classification
  already did, through `Alplus.Orgs.accept_invitation/2` (which re-checks
  status, expiry, and email match inside the Ash action) — the page hides
  the button when a check fails, and the server rejects the event
  regardless, so nothing here is trusted from the client
  (ARCHITECTURE.md: "hide the control AND reject the event").
  """

  use AlplusWeb, :live_view

  on_mount {AlplusWeb.LiveUserAuth, :current_user}

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case Alplus.Orgs.get_invitation_by_token(token) do
      {:ok, invitation} ->
        {:ok,
         socket
         |> assign(:page_title, "Accept invitation")
         |> assign(:robots, "noindex,nofollow")
         |> assign(:token, token)
         |> assign_invitation(invitation)}

      {:error, :not_found} ->
        raise AlplusWeb.NotFoundError
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} title={"Join #{@invitation.organization.name}"}>
      <div id="invitation-accept">
        <div :if={@status == :accepted} id="invitation-message-accepted">
          <.alert
            kind="success"
            title="Invitation already accepted"
            message="This invitation has already been accepted."
          />
          <div class="mt-4">
            <.button
              :if={@current_user}
              navigate={~p"/dashboard"}
              variant="secondary"
              class="w-full"
            >
              Go to your dashboard
            </.button>
            <.button
              :if={is_nil(@current_user)}
              navigate={~p"/sign-in"}
              variant="secondary"
              class="w-full"
            >
              Sign in to see your organizations
            </.button>
          </div>
        </div>

        <div :if={@status == :revoked} id="invitation-message-revoked">
          <.alert
            kind="error"
            title="Invitation revoked"
            message="This invitation has been revoked."
          />
          <p class="mt-2 text-body text-text-secondary">Ask whoever invited you to send a new one.</p>
        </div>

        <div :if={@status == :expired} id="invitation-message-expired">
          <.alert
            kind="warning"
            title="Invitation expired"
            message="This invitation has expired."
          />
          <p class="mt-2 text-body text-text-secondary">Ask whoever invited you to send a new one.</p>
        </div>

        <div :if={@status == :pending}>
          <.alert :if={is_nil(@current_user)} id="invitation-signed-out" kind="info">
            You've been invited to join <strong>{@invitation.organization.name}</strong>
            as <strong>{@invitation.role}</strong>. Sign in or create an account with
            <strong>{@invitation.email}</strong>
            to accept.
          </.alert>

          <div :if={is_nil(@current_user)} class="mt-4 grid gap-3">
            <.button
              navigate={~p"/sign-in"}
              id="invitation-sign-in-link"
              variant="primary"
              class="w-full"
            >
              Sign in
            </.button>
            <.button
              navigate={~p"/register"}
              id="invitation-register-link"
              variant="secondary"
              class="w-full"
            >
              Create an account
            </.button>
          </div>

          <.alert
            :if={@current_user && not @email_matches?}
            id="invitation-email-mismatch"
            kind="warning"
            title="Use the invited email address"
          >
            This invitation was sent to {@invitation.email}, a different address than
            your account's. Sign in with that address to accept it.
          </.alert>

          <div :if={@current_user && @email_matches?}>
            <p id="invitation-details" class="text-body text-text-primary">
              You've been invited to join <strong>{@invitation.organization.name}</strong>
              as <strong>{@invitation.role}</strong>.
            </p>

            <.button
              id="invitation-accept-btn"
              variant="primary"
              phx-click="accept"
              phx-disable-with="Joining..."
              class="mt-4 w-full"
            >
              Accept invitation
            </.button>
          </div>
        </div>
      </div>
    </Layouts.auth>
    """
  end

  @impl true
  def handle_event("accept", _params, socket) do
    %{current_user: current_user, token: token, status: status, email_matches?: matches?} =
      socket.assigns

    if current_user && status == :pending && matches? do
      scope = Alplus.Scope.for_user(current_user.id)

      case Alplus.Orgs.accept_invitation(scope, token) do
        {:ok, _invitation} ->
          # `accept_invitation/2` doesn't load `:organization` on its
          # result — reuse the name already loaded into assigns at mount
          # instead of an extra load just for the flash message.
          {:noreply,
           socket
           |> put_flash(:info, "You've joined #{socket.assigns.invitation.organization.name}.")
           |> push_navigate(
             to:
               ~p"/dashboard/orgs/#{socket.assigns.invitation.organization.public_token}/projects"
           )}

        {:error, error} ->
          case Alplus.Orgs.get_invitation_by_token(token) do
            {:ok, invitation} ->
              {:noreply,
               socket
               |> assign_invitation(invitation)
               |> put_flash(:error, accept_error_message(error))}

            {:error, :not_found} ->
              raise AlplusWeb.NotFoundError
          end
      end
    else
      {:noreply, socket}
    end
  end

  # A bare "Could not accept that invitation." left the recipient with nothing
  # to act on, and hid the only failure that is not their fault: the
  # organization being out of seats. Ash validation messages on this action are
  # written for the person reading them (`AcceptInvitation`, `EnforceSeat`), so
  # show them. Anything unrecognized stays generic rather than leaking
  # internals.
  defp accept_error_message(error) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.find_value(fn
      %{message: message} when is_binary(message) and message != "" -> message
      _ -> nil
    end)
    |> case do
      nil -> "Could not accept that invitation."
      message -> "Could not accept that invitation: #{message}"
    end
  end

  defp assign_invitation(socket, invitation) do
    current_user = socket.assigns[:current_user]

    socket
    |> assign(:invitation, invitation)
    |> assign(:status, classify(invitation))
    |> assign(:email_matches?, email_matches?(current_user, invitation))
  end

  defp classify(%{status: "accepted"}), do: :accepted
  defp classify(%{status: "revoked"}), do: :revoked

  defp classify(%{status: "pending"} = invitation) do
    if DateTime.compare(DateTime.utc_now(), invitation.expires_at) != :lt do
      :expired
    else
      :pending
    end
  end

  defp classify(_invitation), do: :expired

  defp email_matches?(nil, _invitation), do: false

  defp email_matches?(current_user, invitation) do
    normalize(to_string(current_user.email)) == invitation.email
  end

  defp normalize(email), do: email |> String.trim() |> String.downcase()
end
