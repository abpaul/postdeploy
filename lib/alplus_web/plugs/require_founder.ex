defmodule AlplusWeb.Plugs.RequireFounder do
  @moduledoc """
  Allows only confirmed users whose email appears in `FOUNDER_EMAILS`.

  The allowlist is an operational control, not a user attribute. An empty or
  missing allowlist fails closed, and denied requests receive the same 404 as
  an unknown route.
  """

  import Plug.Conn, only: [halt: 1, send_resp: 3]
  import Phoenix.LiveView, only: [redirect: 2]

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{assigns: assigns} = conn, _opts) do
    if allowed?(assigns[:current_user]) do
      conn
    else
      conn
      |> send_resp(:not_found, "")
      |> halt()
    end
  end

  @doc "Returns whether a confirmed user matches the configured founder allowlist."
  @spec allowed?(map() | nil) :: boolean()
  def allowed?(%{email: email, confirmed_at: confirmed_at}) when not is_nil(confirmed_at) do
    email
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> then(&(&1 in Application.get_env(:alplus, :founder_emails, [])))
  end

  def allowed?(_user), do: false

  @doc "LiveView mount hook for founder-only sessions."
  def on_mount(:live, _params, _session, %{assigns: %{current_user: user}} = socket) do
    if allowed?(user) do
      {:cont, socket}
    else
      raise AlplusWeb.NotFoundError
    end
  end

  def on_mount(:live, _params, _session, socket) do
    {:halt, redirect(socket, to: "/sign-in")}
  end
end
