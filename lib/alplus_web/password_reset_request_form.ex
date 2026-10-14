defmodule AlplusWeb.PasswordResetRequestForm do
  @moduledoc false

  use AlplusWeb, :live_component

  alias AshAuthentication.Phoenix.Components.Password.ResetForm
  alias AshPhoenix.Form

  @impl true
  def update(assigns, socket) do
    {:ok, socket} = ResetForm.update(assigns, socket)
    {:ok, assign(socket, reset_error: nil, reset_success: false)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <p :if={@reset_success} role="status" class="mb-4 text-body text-text-secondary">
        If an account uses this email, we'll send a password reset link.
      </p>
      <p
        :if={@reset_error}
        id="reset-request-error"
        role="alert"
        class="mb-4 text-body text-status-error-ink"
      >
        {@reset_error}
      </p>
      {ResetForm.render(assigns)}
    </div>
    """
  end

  @impl true
  def handle_event("submit", params, socket) do
    params = Map.get(params, socket.assigns.form.name, %{})

    case Form.submit(socket.assigns.form, params: params) do
      :ok ->
        success(socket)

      {:ok, _result} ->
        success(socket)

      {:error, form} ->
        {:noreply,
         socket
         |> assign(:reset_success, false)
         |> assign(:form, form)
         |> assign(
           :reset_error,
           "Check your email address and complete the security check, then try again."
         )}
    end
  end

  def handle_event(event, params, socket), do: ResetForm.handle_event(event, params, socket)

  defp success(socket) do
    {:ok, socket} =
      ResetForm.update(Map.take(socket.assigns, [:strategy, :context]), socket)

    {:noreply,
     socket
     |> assign(reset_error: nil, reset_success: true)}
  end
end
