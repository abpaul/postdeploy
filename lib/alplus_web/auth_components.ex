defmodule AlplusWeb.AuthComponents do
  @moduledoc false

  use AlplusWeb, :html

  attr :form, :any, required: true

  def turnstile(assigns), do: render_turnstile(assigns, false)
  def reset_turnstile(assigns), do: render_turnstile(assigns, true)

  def health_turnstile(assigns) do
    assigns = assign(assigns, :form, %{name: "", id: "health-check"})

    render_turnstile(assigns, true,
      token_name: "turnstile_token",
      token_id: "health-check-turnstile-token",
      widget_id: "health-check-turnstile"
    )
  end

  defp render_turnstile(assigns, reset_after_submit?, overrides \\ []) do
    assigns =
      assigns
      |> assign(:site_key, Application.fetch_env!(:alplus, :turnstile_site_key))
      |> assign(
        :token_name,
        Keyword.get(overrides, :token_name, assigns.form.name <> "[turnstile_token]")
      )
      |> assign(
        :token_id,
        Keyword.get(overrides, :token_id, "#{assigns.form.id}-turnstile-token")
      )
      |> assign(:widget_id, Keyword.get(overrides, :widget_id, "#{assigns.form.id}-turnstile"))
      |> assign(:reset_after_submit?, reset_after_submit?)

    ~H"""
    <div
      id={@widget_id}
      phx-hook="AuthTurnstile"
      phx-update="ignore"
      data-sitekey={@site_key}
      data-token-id={@token_id}
      data-reset-after-submit={@reset_after_submit?}
      role="group"
      aria-label="Security check"
    >
      <input type="hidden" name={@token_name} id={@token_id} />
      <div data-turnstile-challenge></div>
      <p data-turnstile-error role="alert" aria-live="assertive" hidden>
        Security check could not load. Try again.
      </p>
      <button data-turnstile-retry type="button" hidden>Retry security check</button>
    </div>
    """
  end
end
