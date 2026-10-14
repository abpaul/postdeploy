defmodule AlplusWeb.RegisterLive do
  @moduledoc """
  PostDeploy-owned registration page (ARCHITECTURE.md §10).

  The stock `AshAuthenticationPhoenix` sign-in/register live view has no way
  to collect a Cloudflare Turnstile response, and `register_with_password`
  now requires one. This view renders the Turnstile widget itself (via a
  colocated JS hook, never an inline `<script>` tag) and posts the token
  through as the `turnstile_token` argument on the same Ash action.

  `Alplus.Accounts.User`'s `:register_with_password` action stays the only
  place a user gets created — this view calls it through `AshPhoenix.Form`
  with no duplicate validation or persistence logic.
  """

  use AlplusWeb, :live_view

  on_mount {AlplusWeb.LiveUserAuth, :live_no_user}

  alias AshPhoenix.Form

  # `CoreComponents.input/1`'s default `rounded-control` resolves to a
  # 9999px pill in the public expression; the mock's auth inputs (06, lines
  # 450-452) are 12px on both sign-in and register — `AuthOverrides`
  # `@base_input` carries the matching value for sign-in.
  @input_class "block min-h-target-min h-control-md w-full rounded-[12px] border border-border-control " <>
                 "bg-surface-raised px-3 text-body text-text-primary placeholder:text-text-tertiary " <>
                 "focus-visible:outline-none focus-visible:shadow-[var(--alp-focus-ring)] " <>
                 "disabled:cursor-not-allowed disabled:border-border-default disabled:bg-hover " <>
                 "disabled:text-text-disabled disabled:placeholder:text-text-disabled"

  defp input_class, do: @input_class

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Create your account")
     |> assign(:turnstile_site_key, Application.fetch_env!(:alplus, :turnstile_site_key))
     |> assign(:auto_signin_token, nil)
     |> assign(:form, build_form())}
  end

  @impl true
  def render(%{auto_signin_token: token} = assigns) when is_binary(token) do
    ~H"""
    <Layouts.auth flash={@flash} title="Setting up your workspace">
      <:subtitle>One moment, taking you straight in.</:subtitle>

      <div class="flex flex-col items-center gap-4 py-4" role="status" aria-live="polite">
        <.skeleton rows={2} class="w-full" />
        <p class="text-body text-text-secondary">Preparing your workspace.</p>
        <%!-- Real, plain HTTP form (never `phx-submit`): the account was
              already created over the socket, but only a real conn can write
              the session cookie, so this hands the sign-in token to
              `AuthController.complete_registration/2` in the POST body
              (never a query string) and the hook auto-submits it. --%>
        <form
          id="complete-registration-form"
          method="post"
          action={~p"/register/complete"}
          phx-hook=".AutoSubmit"
        >
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
          <input type="hidden" name="token" value={@auto_signin_token} />
          <script :type={Phoenix.LiveView.ColocatedHook} name=".AutoSubmit">
            export default {
              mounted() {
                this.el.requestSubmit()
              }
            }
          </script>
          <noscript>
            <.button type="submit" variant="primary">Continue to PostDeploy</.button>
          </noscript>
        </form>
      </div>
    </Layouts.auth>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} title="Create your account.">
      <:cross_link>
        Already have an account? <.button variant="ghost" navigate={~p"/sign-in"}>Sign in</.button>
      </:cross_link>
      <:subtitle>Create an account with your email and a password.</:subtitle>

      <.form
        for={@form}
        id="register-form"
        phx-hook="FocusInvalid"
        phx-change="validate"
        phx-submit="save"
      >
        <.input
          field={@form[:email]}
          type="email"
          label="Email"
          autocomplete="email"
          class={input_class()}
          required
        />
        <.input
          field={password_field(@form)}
          type="password"
          label="Password"
          autocomplete="new-password"
          class={input_class()}
          required
        />
        <.input
          field={password_confirmation_field(@form)}
          type="password"
          label="Confirm password"
          autocomplete="new-password"
          class={input_class()}
          required
        />

        <.input
          field={@form[:turnstile_token]}
          type="hidden"
          id="turnstile-token"
          aria-describedby="turnstile-errors turnstile-load-error"
        />

        <%!-- The hidden input above renders no error text of its own
               (core_components' hidden branch is silent), so a rejected or
               unreachable Turnstile check would otherwise fail invisibly. --%>
        <div
          :if={@form[:turnstile_token].errors != []}
          id="turnstile-errors"
          role="alert"
          aria-live="assertive"
          class="mb-3 space-y-1 text-body text-status-error-ink"
        >
          <p
            :for={{error, index} <- Enum.with_index(@form[:turnstile_token].errors)}
            id={"turnstile-error-#{index}"}
          >
            {translate_error(error)}
          </p>
        </div>

        <div
          id="turnstile-widget"
          phx-hook=".TurnstileWidget"
          phx-update="ignore"
          data-sitekey={@turnstile_site_key}
          role="group"
          aria-label="Security check"
          aria-describedby="turnstile-errors turnstile-load-error"
        >
          <div id="turnstile-challenge"></div>
          <p
            id="turnstile-load-error"
            role="alert"
            aria-live="assertive"
            class="mt-2 text-body text-status-error-ink"
            hidden
          >
            Security check could not load. Use the retry button to try again.
          </p>
          <button
            id="turnstile-retry"
            type="button"
            class="mt-2 inline-flex min-h-target-min items-center rounded-control border border-border-control bg-surface-raised px-3 text-label font-medium text-text-primary hover:bg-hover focus-visible:outline-none focus-visible:shadow-[var(--alp-focus-ring)]"
            aria-describedby="turnstile-load-error"
            hidden
          >
            Retry security check
          </button>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".TurnstileWidget">
            export default {
              mounted() {
                this.el.querySelector("#turnstile-retry").addEventListener("click", () => this.retry())
                this.loadScript()
                  .then(() => this.renderWidget())
                  .catch(() => {
                    this.clearToken()
                    this.setError("Security check could not load. Use the retry button to try again.", true)
                  })
              },
              loadScript() {
                return window.PostDeployTurnstile.load()
              },
              renderWidget() {
                const challenge = this.el.querySelector("#turnstile-challenge")
                this.widgetId = window.turnstile.render(challenge, {
                  sitekey: this.el.dataset.sitekey,
                  size: "flexible",
                  callback: (token) => {
                    const input = document.getElementById("turnstile-token")
                    input.value = token
                    this.clearError()
                    input.dispatchEvent(new Event("input", {bubbles: true}))
                  },
                  "expired-callback": () => {
                    this.clearToken()
                    this.setError("Security check expired. Complete it again.")
                  },
                  "error-callback": () => {
                    this.clearToken()
                    this.setError("Security check could not load. Use the retry button to try again.", true)
                  }
                })
              },
              retry() {
                this.clearToken()
                this.clearWidget()
                this.clearFailedLoad()
                this.clearError()
                this.loadScript()
                  .then(() => this.renderWidget())
                  .catch(() => {
                    this.setError("Security check could not load. Use the retry button to try again.", true)
                  })
              },
              clearFailedLoad() {
                return undefined
              },
              clearWidget() {
                if (
                  this.widgetId &&
                  window.turnstile &&
                  typeof window.turnstile.remove === "function"
                ) {
                  window.turnstile.remove(this.widgetId)
                }

                this.widgetId = null
                const challenge = this.el.querySelector("#turnstile-challenge")
                if (challenge) challenge.replaceChildren()
              },
              clearToken() {
                const input = document.getElementById("turnstile-token")
                if (input && input.value) {
                  input.value = ""
                  input.dispatchEvent(new Event("input", {bubbles: true}))
                }
              },
              setError(message, retryable = false) {
                const error = document.getElementById("turnstile-load-error")
                if (error) {
                  error.textContent = message
                  error.hidden = false
                }
                const retry = this.el.querySelector("#turnstile-retry")
                if (retry) retry.hidden = !retryable
                this.el.setAttribute("aria-invalid", "true")
              },
              clearError() {
                const error = document.getElementById("turnstile-load-error")
                if (error) error.hidden = true
                const retry = this.el.querySelector("#turnstile-retry")
                if (retry) retry.hidden = true
                this.el.removeAttribute("aria-invalid")
              }
            }
          </script>
        </div>

        <.button
          phx-disable-with="Creating account..."
          id="register-submit"
          variant="primary"
          class="w-full"
        >
          Create account
        </.button>
      </.form>
    </Layouts.auth>
    """
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    form = socket.assigns.form |> Form.validate(params, errors: false) |> to_form()
    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"user" => params}, socket) do
    case Form.submit(socket.assigns.form, params: params) do
      {:ok, user} ->
        # `user.__metadata__.token` is the sign-in JWT
        # `AshAuthentication.GenerateTokenChange` minted for this same
        # `:register_with_password` action — not the confirmation link
        # token (that one lives at `__metadata__.confirmation_token` and
        # was already emailed by `ConfirmationHookChange`).
        {:noreply, assign(socket, :auto_signin_token, user.__metadata__.token)}

      {:error, form} ->
        {:noreply, assign(socket, :form, to_form(form))}
    end
  end

  # `private.ash_authentication?` satisfies the bypass on
  # `Alplus.Accounts.User`'s policies
  # (`AshAuthentication.Checks.AshAuthenticationInteraction`) the same way
  # the stock AshAuthenticationPhoenix register form does — this view calls
  # the action directly rather than through the strategy dispatcher, so the
  # context has to be set explicitly instead of picked up automatically.
  defp build_form do
    Alplus.Accounts.User
    |> Form.for_create(:register_with_password,
      domain: Alplus.Accounts,
      as: "user",
      context: %{private: %{ash_authentication?: true}}
    )
    |> to_form()
  end

  # Ash's `length` validation on `:password` and the confirmation check on
  # `:password_confirmation` both surface raw messages ("length must be
  # greater than or equal to 8", "does not match confirmation") straight
  # from `CoreComponents.translate_error/1`. Rewriting them here (via the
  # `<.input>` `field` override) names the problem and the recovery instead,
  # without touching the shared `translate_error/1` every other form relies
  # on for its generic Ash/Ecto error text.
  @password_copy [
    {"length must be greater than or equal to",
     "Needs at least 8 characters. Add a few more and try again."}
  ]
  @password_confirmation_copy [
    {"does not match confirmation",
     "Doesn't match the password above. Re-enter it and try again."},
    {"does not match", "Doesn't match the password above. Re-enter it and try again."}
  ]

  defp password_field(form), do: friendly_errors(form[:password], @password_copy)

  defp password_confirmation_field(form),
    do: friendly_errors(form[:password_confirmation], @password_confirmation_copy)

  defp friendly_errors(field, copy) do
    errors =
      Enum.map(field.errors, fn {msg, opts} ->
        case Enum.find(copy, fn {prefix, _friendly} -> String.starts_with?(msg, prefix) end) do
          {_prefix, friendly} -> {friendly, []}
          nil -> {msg, opts}
        end
      end)

    %{field | errors: errors}
  end
end
