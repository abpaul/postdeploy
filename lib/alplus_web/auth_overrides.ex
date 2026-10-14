defmodule AlplusWeb.AuthOverrides do
  @moduledoc """
  Styles the stock `AshAuthenticationPhoenix` sign-in, reset, and confirm
  components against the Alplus tokens (ARCHITECTURE.md §9, BUILD.md Phase 5).

  These pages are never forked — only strategy is `Elixir.AshAuthentication.Phoenix.Overrides.Default`
  is listed second in `router.ex`'s `overrides:` list, and every visual
  property that module sets with a raw Tailwind color/size class (dead
  after `theme.css`'s wipe) is overridden here with a token class instead.
  Only `PostDeploy` authenticates with email/password (ARCHITECTURE.md §10) — no
  OAuth2, Apple, or magic-link overrides are needed.

  The shared `AlplusWeb.Layouts.auth_live/1` shell supplies the semantic logo
  link and page heading. The stock Banner is disabled because the dependency's
  implementation cannot provide an image alt/name or a semantic heading tag.
  """
  use AshAuthentication.Phoenix.Overrides

  alias AshAuthentication.Phoenix.{Components, ConfirmLive, ResetLive, SignInLive}

  # Rendered inside `Layouts.auth_live`'s form pane, which owns the page
  # frame; the live-route root must not re-center or re-stretch it.
  @page_root "w-full"
  # The split `Layouts.auth_live` scene owns width, padding, and surface;
  # the strategy column is cardless inside its 380px-max form pane.
  @card "w-full"
  # Each strategy component (`SignInForm`, `Reset.Form`, `Confirm.Form`)
  # renders its own `h2` label ("Sign In", "Reset Password", …) below
  # `Layouts.auth_live`'s own `h1`. Rather than duplicate that heading
  # visually, it stays in the accessibility tree (`sr-only`) as a landmark
  # — the page still reads as one visible heading per screen.
  @heading "sr-only"

  @submit """
  inline-flex min-h-target-min h-control-md w-full items-center justify-center gap-2 rounded-control
  border-2 border-interactive-primary bg-interactive-primary px-4 text-label font-bold text-interactive-ink
  hover:border-interactive-hover hover:bg-interactive-hover focus-visible:outline-none
  focus-visible:shadow-[var(--alp-focus-ring)]
  disabled:cursor-not-allowed disabled:opacity-45 mt-2
  """

  @base_input """
  block min-h-target-min h-control-md w-full rounded-input border bg-surface-raised px-3 text-body
  text-text-primary placeholder:text-text-tertiary focus-visible:outline-none
  focus-visible:shadow-[var(--alp-focus-ring)]
  """

  override SignInLive do
    set :root_class, @page_root
  end

  override Components.SignIn do
    set :root_class, "w-full"
    set :strategy_class, @card
    set :show_banner, false
    set :authentication_error_container_class, "mb-4 text-center text-body text-status-error-ink"
    set :authentication_error_text_class, ""
  end

  # The PostDeploy mark, then the page's heading text, above every Ash-owned auth
  # card — matching `Layouts.auth`'s mark-then-title-then-card order. Same
  # asset and size as `CoreComponents.logo/1` in its `:mark`/`:lg` form. The
  # mark SVG is ink-on-transparent, so the dark canvas swaps in the white
  # variant. `text` and `text_class` are left unset here —
  # each route sets its own heading via a small override module
  # (`SignInBanner`, `ResetBanner`, `ConfirmNewUserBanner`,
  # `ConfirmEmailChangeBanner`, below) listed before this module in
  # `router.ex`'s `overrides:` list, since sign-in/reset/confirm need
  # different heading text but share every other Banner property.
  override Components.Banner do
    set :root_class, "mb-6 flex w-full max-w-sm flex-col items-center"
    set :href_url, "/"
    set :href_class, "inline-flex"
    set :image_url, "/images/postdeploy-mark.svg"
    set :image_class, "h-11 w-11"
    set :dark_image_url, "/images/postdeploy-mark-dark.svg"
  end

  override Components.HorizontalRule do
    set :root_class, "relative my-4"
    set :hr_outer_class, "absolute inset-0 flex items-center"
    set :hr_inner_class, "w-full border-t border-border-default"
    set :text_outer_class, "relative flex justify-center text-label"
    set :text_inner_class, "bg-surface-raised px-2 font-medium text-text-tertiary"
    set :text, "or"
  end

  override Components.Flash do
    set :message_class_info, """
    fixed top-2 right-2 z-50 w-80 max-w-[calc(100vw-1rem)] rounded-frame border
    border-status-neutral-border bg-status-neutral-bg p-3 text-body text-status-neutral-ink sm:w-96
    """

    set :message_class_error, """
    fixed top-2 right-2 z-50 w-80 max-w-[calc(100vw-1rem)] rounded-frame border
    border-status-error-border bg-status-error-bg p-3 text-body text-status-error-ink sm:w-96
    """
  end

  # Hide the stock register form on the sign-in page. It posts without a
  # Turnstile token, so `register_with_password` always rejects it. Sign-up
  # lives at `/register` (AlplusWeb.RegisterLive), which renders the widget.
  # The "New here? Create an account" link now lives in `Layouts.auth_live`'s
  # header row instead (mock 06) — `AlplusWeb.AuthPageTitle`'s `:sign_in`
  # on_mount hook supplies its text and path, so no `sign_in_extra_component`
  # is needed here any more.
  override Components.Password do
    set :root_class, nil
    set :sign_in_form_module, AlplusWeb.AuthOverrides.SignInForm

    # Mock 06's "quiet footer link" row: just "Forgot your password?",
    # centered under the submit button.
    set :interstitial_class,
        "mt-3 flex min-h-target-min items-center justify-center text-body font-medium"

    set :toggler_class,
        "text-text-tertiary underline-offset-4 hover:text-text-secondary hover:underline"

    set :register_toggle_text, nil
    set :reset_toggle_text, "Forgot your password?"
    set :sign_in_extra_component, &AlplusWeb.AuthComponents.turnstile/1
    set :reset_extra_component, &AlplusWeb.AuthComponents.reset_turnstile/1
    set :reset_form_module, AlplusWeb.PasswordResetRequestForm
  end

  override Components.Password.SignInForm do
    set :root_class, nil
    set :label_class, @heading
    set :form_class, nil
    set :slot_class, "my-4"
    set :button_text, "Sign in"
    set :disable_button_text, "Signing in..."
  end

  override AlplusWeb.AuthOverrides.SignInForm do
    set :root_class, nil
    set :label_class, @heading
    set :form_class, nil
    set :slot_class, "my-4"
    set :button_text, "Sign in"
    set :disable_button_text, "Signing in..."
    set :field_class, "mb-4"
    set :input_label_class, "mb-1 block text-label font-semibold text-text-secondary"
    set :identity_input_label, "Email"
    set :identity_input_placeholder, nil
    set :password_input_label, "Password"
    set :input_class, @base_input <> "border-border-control"
    set :input_class_with_error, @base_input <> "border-status-error-border"
    set :input_debounce, 350
    set :error_ul, "mt-1.5 text-body text-status-error-ink"
    set :error_li, nil
  end

  override Components.Password.ResetForm do
    set :root_class, nil
    set :label_class, @heading
    set :form_class, nil
    set :slot_class, "my-4"
    set :button_text, "Send reset link"
    set :disable_button_text, "Requesting..."
  end

  override Components.Password.Input do
    set :field_class, "mb-4"
    set :label_class, "mb-1 block text-label font-semibold text-text-secondary"
    set :input_class, @base_input <> "border-border-control"
    set :input_class_with_error, @base_input <> "border-status-error-border"
    set :submit_class, @submit
    set :error_ul, "mt-1.5 text-body text-status-error-ink"
    set :error_li, nil
    set :remember_me_class, "mt-2 mb-2 flex items-center gap-2 text-body text-text-primary"

    set :checkbox_class,
        "mr-2 size-4 rounded-control border-border-strong text-interactive-strong"

    set :checkbox_label_class, "text-body font-medium text-text-primary"
  end

  override ResetLive do
    set :root_class, @page_root
  end

  override Components.Reset do
    set :root_class, "w-full"
    set :strategy_class, @card
    set :show_banner, false
  end

  override Components.Reset.Form do
    set :root_class, nil
    set :label_class, @heading
    set :form_class, nil
    set :spacer_class, "py-1"
    set :button_text, "Change password"
    set :disable_button_text, "Changing password..."
  end

  override ConfirmLive do
    set :root_class, @page_root
  end

  override Components.Confirm do
    set :root_class, "w-full"
    set :strategy_class, @card
    set :show_banner, false
  end

  override Components.Confirm.Form do
    set :label_class, @heading
  end

  override Components.Confirm.Input do
    set :submit_class, @submit
  end
end

defmodule AlplusWeb.AuthOverrides.SignInBanner do
  @moduledoc """
  Retained for route compatibility; `Layouts.auth_live/1` owns the heading.
  """
  use AshAuthentication.Phoenix.Overrides
  alias AshAuthentication.Phoenix.Components

  override Components.Banner do
    set :text, "Welcome back"
    set :text_class, "mt-4 text-center text-heading-01 font-semibold text-text-primary"
  end
end

defmodule AlplusWeb.AuthOverrides.ResetBanner do
  @moduledoc """
  Retained for route compatibility; `Layouts.auth_live/1` owns the heading.
  """
  use AshAuthentication.Phoenix.Overrides
  alias AshAuthentication.Phoenix.Components

  override Components.Banner do
    set :text, "Reset your password"
    set :text_class, "mt-4 text-center text-heading-01 font-semibold text-text-primary"
  end
end

defmodule AlplusWeb.AuthOverrides.ConfirmNewUserBanner do
  @moduledoc """
  Retained for route compatibility; `Layouts.auth_live/1` owns the heading.
  """
  use AshAuthentication.Phoenix.Overrides
  alias AshAuthentication.Phoenix.Components

  override Components.Banner do
    set :text, "Confirm your account"
    set :text_class, "mt-4 text-center text-heading-01 font-semibold text-text-primary"
  end
end

defmodule AlplusWeb.AuthOverrides.ConfirmEmailChangeBanner do
  @moduledoc """
  Retained for route compatibility; `Layouts.auth_live/1` owns the heading.
  """
  use AshAuthentication.Phoenix.Overrides
  alias AshAuthentication.Phoenix.Components

  override Components.Banner do
    set :text, "Confirm your new email"
    set :text_class, "mt-4 text-center text-heading-01 font-semibold text-text-primary"
  end
end

defmodule AlplusWeb.AuthOverrides.SignInForm do
  use AshAuthentication.Phoenix.Web, :live_component

  use AshAuthentication.Phoenix.Overrides.Overridable,
    root_class: "",
    label_class: "",
    form_class: "",
    slot_class: "",
    button_text: "Sign in",
    disable_button_text: "Signing in...",
    field_class: "",
    input_label_class: "",
    input_class: "",
    input_class_with_error: "",
    identity_input_label: "Email",
    identity_input_placeholder: "",
    password_input_label: "Password",
    input_debounce: "",
    error_ul: "",
    error_li: ""

  alias AshAuthentication.{Info, Phoenix.Components.Password, Strategy}
  alias AshAuthentication.Phoenix.Components.Helpers
  alias AshPhoenix.Form
  alias Phoenix.LiveView.{Rendered, Socket}

  import AshAuthentication.Phoenix.Components.Helpers,
    only: [auth_path: 5, auth_path: 6, debug_form_errors: 1]

  import PhoenixHTMLHelpers.Form
  import Slug

  @impl true
  def update(assigns, socket) do
    strategy = assigns.strategy
    domain = Info.authentication_domain!(strategy.resource)
    subject_name = Info.authentication_subject_name!(strategy.resource)

    socket =
      socket
      |> assign(assigns)
      |> assign(trigger_action: false, subject_name: subject_name)
      |> assign_new(:label, fn -> humanize(strategy.sign_in_action_name) end)
      |> assign_new(:inner_block, fn -> nil end)
      |> assign_new(:overrides, fn -> [AshAuthentication.Phoenix.Overrides.Default] end)
      |> assign_new(:gettext_fn, fn -> nil end)
      |> assign_new(:current_tenant, fn -> nil end)
      |> assign_new(:context, fn -> %{} end)
      |> assign_new(:auth_routes_prefix, fn -> nil end)
      |> assign_new(:remember_me_field, fn -> Helpers.remember_me_field(assigns.strategy) end)

    context =
      Ash.Helpers.deep_merge_maps(assigns[:context] || %{}, %{
        strategy: strategy,
        private: %{ash_authentication?: true}
      })

    context =
      if Map.get(socket.assigns.strategy, :sign_in_tokens_enabled?) do
        context
        |> Map.put(:token_type, :sign_in)
        |> put_in([:private, :skip_remember_me_token_generation], true)
      else
        context
      end

    form =
      strategy.resource
      |> Form.for_action(strategy.sign_in_action_name,
        domain: domain,
        as: subject_name |> to_string() |> slugify(),
        id:
          "#{subject_name}-#{Strategy.name(strategy)}-#{strategy.sign_in_action_name}"
          |> slugify(),
        tenant: assigns[:current_tenant],
        transform_errors: _transform_errors(),
        context: context
      )

    socket = assign(socket, form: form, trigger_action: false, subject_name: subject_name)

    {:ok, socket}
  end

  @impl true
  @spec render(Socket.assigns()) :: Rendered.t() | no_return
  def render(assigns) do
    identity_field = assigns.strategy.identity_field
    password_field = assigns.strategy.password_field

    assigns =
      assigns
      |> assign(:identity_field, identity_field)
      |> assign(:password_field, password_field)
      |> assign(:identity_input_type, identity_input_type(identity_field))

    ~H"""
    <div class={override_for(@overrides, :root_class)}>
      <%= if @label do %>
        <h2 class={override_for(@overrides, :label_class)}>{_gettext(@label)}</h2>
      <% end %>

      <.form
        :let={form}
        for={@form}
        id={@form.id}
        phx-change="change"
        phx-submit="submit"
        phx-trigger-action={@trigger_action}
        phx-target={@myself}
        action={auth_path(@socket, @subject_name, @auth_routes_prefix, @strategy, :sign_in)}
        method="POST"
        class={override_for(@overrides, :form_class)}
      >
        <div class={override_for(@overrides, :field_class)}>
          {label(
            form,
            @identity_field,
            _gettext(override_for(@overrides, :identity_input_label, "Email")),
            class: override_for(@overrides, :input_label_class)
          )}
          {text_input(form, @identity_field,
            type: @identity_input_type,
            class: input_class(form, @identity_field, @overrides),
            phx_debounce: override_for(@overrides, :input_debounce),
            autofocus: "true",
            placeholder: override_for(@overrides, :identity_input_placeholder),
            autocomplete: "username"
          )}
          <Password.Input.error
            form={form}
            field={@identity_field}
            overrides={@overrides}
            gettext_fn={@gettext_fn}
          />
        </div>

        <div class={override_for(@overrides, :field_class)}>
          {label(
            form,
            @password_field,
            _gettext(override_for(@overrides, :password_input_label, "Password")),
            class: override_for(@overrides, :input_label_class)
          )}
          {password_input(form, @password_field,
            class: input_class(form, @password_field, @overrides),
            phx_debounce: override_for(@overrides, :input_debounce),
            autocomplete: "current-password"
          )}
          <Password.Input.error
            form={form}
            field={@password_field}
            overrides={@overrides}
            gettext_fn={@gettext_fn}
          />
        </div>

        <%= if @inner_block do %>
          <div class={override_for(@overrides, :slot_class)}>
            {render_slot(@inner_block, form)}
          </div>
        <% end %>

        <Password.Input.remember_me_field
          :if={@remember_me_field}
          name={@remember_me_field}
          form={form}
          overrides={@overrides}
          gettext_fn={@gettext_fn}
        />

        <Password.Input.submit
          strategy={@strategy}
          id={@form.id <> "-submit"}
          form={form}
          action={:sign_in}
          label={override_for(@overrides, :button_text)}
          disable_text={override_for(@overrides, :disable_button_text)}
          overrides={@overrides}
          gettext_fn={@gettext_fn}
        />
      </.form>
    </div>
    """
  end

  @impl true
  def handle_event("change", params, socket) do
    params = get_params(params, socket.assigns.strategy)
    form = socket.assigns.form |> Form.validate(params, errors: false)
    {:noreply, assign(socket, form: form)}
  end

  def handle_event("submit", params, socket) do
    params = get_params(params, socket.assigns.strategy)

    if Map.get(socket.assigns.strategy, :sign_in_tokens_enabled?) do
      case Form.submit(socket.assigns.form, params: params, read_one?: true) do
        {:ok, user} ->
          auth_path_params = get_auth_path_params(params, user)

          validate_sign_in_token_path =
            auth_path(
              socket,
              socket.assigns.subject_name,
              socket.assigns.auth_routes_prefix,
              socket.assigns.strategy,
              :sign_in_with_token,
              auth_path_params
            )

          {:noreply, redirect(socket, to: validate_sign_in_token_path)}

        {:error, form} ->
          debug_form_errors(form)

          {:noreply,
           assign(socket, :form, Form.clear_value(form, socket.assigns.strategy.password_field))}
      end
    else
      form = Form.validate(socket.assigns.form, params)

      socket =
        socket
        |> assign(:form, form)
        |> assign(:trigger_action, form.valid?)

      {:noreply, socket}
    end
  end

  defp input_class(form, field, overrides) do
    if form |> Form.errors() |> Keyword.has_key?(field) do
      override_for(overrides, :input_class_with_error)
    else
      override_for(overrides, :input_class)
    end
  end

  defp identity_input_type(field) do
    if field |> to_string() |> String.contains?("email"), do: "email", else: "text"
  end

  defp get_auth_path_params(params, user) do
    case Map.get(params, "remember_me") do
      nil -> %{token: user.__metadata__.token}
      remember_me -> %{token: user.__metadata__.token, remember_me: remember_me}
    end
  end

  defp get_params(params, strategy) do
    param_key =
      strategy.resource
      |> Info.authentication_subject_name!()
      |> to_string()
      |> slugify()

    Map.get(params, param_key, %{})
  end
end
