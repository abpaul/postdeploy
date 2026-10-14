defmodule AlplusWeb.ConfirmEmailBanner do
  @moduledoc """
  Dismissible "Confirm your email" banner shown in the dashboard shell
  while `current_user.confirmed_at` is nil (ARCHITECTURE.md §10, onboarding
  overhaul decision #1: the dashboard is usable before confirmation — this
  is a nudge, never a gate).

  A `Phoenix.LiveComponent`, not a plug/gate: the dismiss/resend state is
  local to this one banner, so every dashboard LiveView gets it for free
  from `dashboard_shell/1` without adding `handle_event` clauses of its
  own.
  """

  use AlplusWeb, :live_component

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:dismissed?, fn -> false end)
     |> assign_new(:notice, fn -> nil end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="confirm-email-banner">
      <div
        :if={not @dismissed? and is_nil(@current_user.confirmed_at)}
        id="confirm-email-banner-content"
        class="mb-6 flex flex-wrap items-center justify-between gap-3 border border-status-late-border bg-status-late-bg px-4 py-3 text-data text-status-late-ink"
      >
        <p class="flex flex-wrap items-center gap-2">
          <.icon name="hero-envelope" class="size-4 shrink-0" />
          <span :if={is_nil(@notice)}>
            Confirm your email to invite teammates and secure your account.
          </span>
          <span :if={@notice} id="confirm-email-notice">{@notice}</span>
          <button
            :if={is_nil(@notice)}
            type="button"
            id="confirm-email-resend"
            phx-click="resend"
            phx-target={@myself}
            phx-disable-with="Sending..."
            class="font-medium underline hover:opacity-80"
          >
            Resend confirmation email
          </button>
        </p>
        <button
          type="button"
          id="confirm-email-dismiss"
          phx-click="dismiss"
          phx-target={@myself}
          aria-label="Dismiss"
          class="shrink-0 text-status-late-ink hover:opacity-70"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("dismiss", _params, socket) do
    {:noreply, assign(socket, :dismissed?, true)}
  end

  def handle_event("resend", _params, socket) do
    case Alplus.Accounts.ResendConfirmation.resend(socket.assigns.current_user) do
      :ok ->
        {:noreply, assign(socket, :notice, "Confirmation email sent. Check your inbox.")}

      {:error, :already_confirmed} ->
        {:noreply, assign(socket, :dismissed?, true)}

      {:error, _reason} ->
        {:noreply, assign(socket, :notice, "Could not send that email. Try again shortly.")}
    end
  end
end
