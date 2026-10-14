defmodule AlplusWeb.CoreComponents do
  @moduledoc """
  Core UI building blocks (forms, buttons, tables, flashes, skeletons),
  styled against the Alplus tokens in `assets/css/alp/` (ARCHITECTURE.md
  §9, BUILD.md Phase 5). No daisyUI, no default Tailwind palette — every
  class here resolves to a `--alp-*` token or a plain layout utility
  (spacing, flex, grid) that the wipe in `theme.css` never touches.

  Vocabulary: new surfaces use `text-primary`/`text-secondary`/`text-tertiary`,
  `surface-page`/`surface-raised`/`surface-sunken`, and
  `interactive-primary`/`interactive-tint`. State uses the explicit
  `status-live`/`status-error`/`status-late`/`status-paused`/`status-neutral`
  roles. The legacy `ink`/`canvas`/`accent` aliases stay available until #96.
  """
  use Phoenix.Component
  use Gettext, backend: AlplusWeb.Gettext
  use AlplusWeb, :verified_routes

  alias Phoenix.LiveView.JS

  @doc """
  Renders a flash/toast notice.

  Floats bottom-right (mock 09 "FEEDBACK"): bordered hairline, `shadow-toast`,
  a status dot, never a filled wall of color. Info flashes auto-dismiss after
  five seconds (`.AutoDismissFlash`); errors keep the manual close only, so
  the reader cannot miss them. Put an "Undo" affordance in the inner block
  when the action it confirms is undoable.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-hook={@kind == :info && "AlplusWeb.CoreComponents.AutoDismissFlash"}
      role="alert"
      class="fixed bottom-4 right-4 z-50 flex w-80 max-w-[calc(100vw-2rem)] items-start gap-3 rounded-overlay border border-border-default bg-surface-raised p-3.5 text-body shadow-toast sm:w-96"
      {@rest}
    >
      <span
        class={[
          "mt-1.5 size-[7px] shrink-0 rounded-dot",
          @kind == :error && "bg-status-error",
          @kind != :error && "bg-status-live"
        ]}
        aria-hidden="true"
      />
      <div class="min-w-0 flex-1">
        <p :if={@title} class={["font-semibold", @kind == :error && "text-status-error-ink"]}>
          {@title}
        </p>
        <p class="text-wrap text-text-primary">{msg}</p>
      </div>
      <button
        type="button"
        data-flash-close
        phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
        class="flex h-control-md w-control-md shrink-0 cursor-pointer items-center justify-center rounded-control-sm text-text-tertiary transition-opacity duration-productive hover:text-text-primary"
        aria-label={gettext("close")}
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".AutoDismissFlash">
      export default {
        mounted() {
          // Info flashes are transient confirmations; dismiss them after a few
          // seconds so a success message never sticks. Errors keep the manual
          // close only, so the reader cannot miss them.
          this._timer = setTimeout(() => this.el.querySelector("[data-flash-close]")?.click(), 5000)
        },
        destroyed() {
          clearTimeout(this._timer)
        }
      }
    </script>
    """
  end

  @doc """
  Renders the canonical PostDeploy logo lockup — the one place the brand mark and
  wordmark are drawn.

  Do not hand-build a logo from an image element plus a text "PostDeploy" anywhere else;
  call this so every lockup shares one asset, one spacing, and one a11y
  contract. The balancing-rock mark is mirrored in
  `priv/static/images/postdeploy-mark.svg`. The inline mark follows the primary
  text color so it remains black in light mode and white in dark mode.

  Variants:
    * `:full` — mark + "PostDeploy" wordmark (default). Navigation, headers, footer.
    * `:mark` — the brand glyph alone. Auth/empty hero, tight spaces.
    * `:wordmark` — the "PostDeploy" wordmark alone.

  Sizes:
    * `:sm` — 24px mark, label wordmark. Every nav bar (default).
    * `:lg` — 44px mark, title wordmark. Auth hero.

  Pass `href` to render the lockup as a link. The accessible name then comes
  from `label` and the mark stays decorative, so a screen reader announces
  "PostDeploy home" once, not twice.

  ## Examples

      <.logo href={~p"/"} />
      <.logo variant={:mark} size={:lg} label="PostDeploy" />
      <.logo variant={:wordmark} />
  """
  attr :variant, :atom, default: :full, values: [:full, :mark, :wordmark]
  attr :size, :atom, default: :sm, values: [:sm, :lg]
  attr :href, :string, default: nil, doc: "when set, wraps the lockup in a link to this path"

  attr :label, :string,
    default: "PostDeploy home",
    doc: "accessible name for the link, or for a standalone mark"

  attr :class, :any, default: nil, doc: "extra classes on the root element"
  attr :rest, :global

  def logo(assigns) do
    # {mark size classes, intrinsic px}. Width and height attributes prevent
    # layout shift.
    marks = %{sm: {"size-6", 24}, lg: {"size-11", 44}}
    words = %{sm: "text-label", lg: "text-heading-02"}
    {mark_class, mark_px} = Map.fetch!(marks, assigns.size)

    assigns =
      assigns
      |> assign(mark_class: mark_class, mark_px: mark_px)
      |> assign(:word_class, Map.fetch!(words, assigns.size))
      |> assign(:show_mark, assigns.variant != :wordmark)
      |> assign(:show_word, assigns.variant != :mark)
      |> assign(:root_class, ["inline-flex items-center gap-[9px]", assigns.class])
      # A standalone unlinked mark carries the name itself; everywhere else the
      # anchor label or the wordmark text already names PostDeploy, so the mark
      # stays decorative.
      |> assign(:mark_named, is_nil(assigns.href) and assigns.variant == :mark)

    if assigns.href do
      ~H"""
      <a href={@href} aria-label={@label} class={@root_class} {@rest}>
        <.logo_mark :if={@show_mark} class={@mark_class} px={@mark_px} />
        <.logo_word :if={@show_word} class={@word_class} />
      </a>
      """
    else
      ~H"""
      <span class={@root_class} {@rest}>
        <.logo_mark :if={@show_mark} class={@mark_class} px={@mark_px} label={@mark_named && @label} />
        <.logo_word :if={@show_word} class={@word_class} />
      </span>
      """
    end
  end

  attr :class, :any, default: nil

  defp logo_word(assigns) do
    ~H"""
    <span class={[
      "font-public font-bold leading-none tracking-[-0.01em] text-text-primary",
      @class
    ]}>
      postdeploy<span class="text-interactive-outline">.</span>
    </span>
    """
  end

  # The PostDeploy mark. Geometry mirrors priv/static/images/postdeploy-mark.svg;
  # keep the two in sync.
  # `label` falsy = decorative.
  attr :px, :integer, required: true
  attr :class, :any, default: nil
  attr :label, :any, default: nil

  defp logo_mark(assigns) do
    ~H"""
    <svg
      viewBox="0 0 512 512"
      width={@px}
      height={@px}
      class={["shrink-0", @class]}
      role={(@label && "img") || nil}
      aria-label={@label || nil}
      aria-hidden={if(@label, do: nil, else: "true")}
    >
      <path
        fill="#C0DF16"
        d="M96 190C60 150 90 105 150 80C230 42 345 25 408 60C458 88 452 141 394 176C328 216 198 240 140 228C112 222 104 208 96 190Z"
      />
      <path
        fill="#171B12"
        d="M258 234C330 226 400 292 434 370C462 434 428 466 350 471C268 476 162 474 116 455C72 437 66 396 96 342C126 289 192 241 258 234Z"
      />
    </svg>
    """
  end

  @doc """
  Renders a labeled ruler for measured time or deployment events.

  `labels` supplies the visible endpoints or scale labels. `markers` is a list
  of maps with a numeric `:position` from 0 to 100, a human `:label`, and an
  optional `:kind` of `:deploy` or `:incident`. Every marker receives an
  accessible name, and invalid positions are not rendered.

  ## Examples

      <.ruler
        labels={["12:00", "12:30", "now"]}
        label="Deploy timeline"
        markers={[%{position: 42, label: "deploy v2.4.1", kind: :deploy}]}
      />
  """
  attr :labels, :list, required: true, doc: "visible ruler labels from start to end"
  attr :markers, :list, default: [], doc: "positioned marker maps"
  attr :label, :string, default: nil, doc: "accessible name for the ruler group"
  attr :class, :any, default: nil
  attr :rest, :global

  def ruler(assigns) do
    validate_ruler_labels!(assigns.labels)
    markers = Enum.filter(assigns.markers, &valid_marker?/1)
    assigns = assign(assigns, :valid_markers, markers)

    ~H"""
    <div
      class={@class}
      role="group"
      aria-label={@label || "Ruler"}
      {@rest}
    >
      <div class="flex items-start justify-between gap-3 text-data font-mono text-text-tertiary">
        <span :for={scale_label <- @labels}>{scale_label}</span>
      </div>
      <div class="alp-ruler-track relative mt-1 h-6" aria-hidden={@valid_markers == [] && "true"}>
        <span
          :for={marker <- @valid_markers}
          class="alp-ruler-marker"
          data-kind={marker_kind(marker)}
          style={"left: #{marker_position(marker)}%"}
          role="img"
          aria-label={marker_label(marker)}
        />
        <span
          :for={marker <- @valid_markers}
          :if={marker_kind(marker) == :deploy}
          class="pointer-events-none absolute -top-6 -translate-x-1/2 whitespace-nowrap rounded-dot bg-surface-inverse px-2 py-0.5 text-[10px] font-medium text-interactive-wash"
          style={"left: #{marker_position(marker)}%"}
          aria-hidden="true"
        >
          ▲ {marker_label(marker)}
        </span>
      </div>
    </div>
    """
  end

  defp validate_ruler_labels!(labels) when is_list(labels) do
    if Enum.any?(labels, &visible_ruler_label?/1) do
      labels
    else
      raise ArgumentError, "ruler/1 requires at least one non-empty visible label"
    end
  end

  defp validate_ruler_labels!(_labels) do
    raise ArgumentError, "ruler/1 labels must be a list with at least one non-empty visible label"
  end

  defp visible_ruler_label?(label) when is_binary(label), do: String.trim(label) != ""
  defp visible_ruler_label?(label) when is_number(label), do: true

  defp visible_ruler_label?(label) when is_atom(label),
    do: label != nil and Atom.to_string(label) != ""

  defp visible_ruler_label?(_label), do: false

  defp valid_marker?(%{position: position}) when is_number(position),
    do: position >= 0 and position <= 100

  defp valid_marker?(_marker), do: false

  defp marker_position(%{position: position}), do: position

  defp marker_kind(%{kind: kind}) when kind in [:deploy, :incident], do: kind
  defp marker_kind(_marker), do: :deploy

  defp marker_label(%{label: label}) when is_binary(label) and byte_size(label) > 0, do: label
  defp marker_label(%{kind: :incident}), do: "Incident marker"
  defp marker_label(_marker), do: "Deploy marker"

  @doc """
  Renders a button with navigation support.

  One system, two expressions, same variant names — `bg-action-primary`
  resolves to ink in the console and chartreuse on public pages, so
  callers never branch on expression.

  `variant`:
    * `"primary"` — one per view. Uses `bg-action-primary` /
      `text-action-primary-ink` (ink fill in the console, chartreuse on
      public). Never a hard-coded chartreuse in dashboard chrome.
    * `"secondary"` — hairline border, raised surface.
    * `"ghost"` — low-emphasis text action; in the public scope this
      becomes the tertiary link (ink text, 2px chartreuse underline).
    * `"destructive"` — bordered until hover, text-only red; always pairs
      with a confirmation (`destructive_confirm/1` or `modal/1`).
    * `"destructive-solid"` — filled red, white text; the modal footer's
      final "Delete" action only.

  Pass `icon_only` for a square icon trigger (e.g. the row overflow "…").

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button variant="destructive">Delete</.button>
      <.button navigate={~p"/"}>Home</.button>
      <.button icon_only variant="secondary" aria-label="More"><.icon name="hero-ellipsis-horizontal" /></.button>
  """
  attr :rest, :global,
    include:
      ~w(type href navigate patch method download name value disabled form target rel formnovalidate autofocus)

  attr :class, :any
  attr :variant, :string, values: ~w(primary secondary ghost destructive destructive-solid)

  attr :icon_only, :boolean,
    default: false,
    doc: "square control (no label text) for an icon-only trigger"

  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    base =
      "inline-flex h-control-md w-fit cursor-pointer items-center justify-center gap-2 " <>
        "rounded-control text-label transition-[color,background-color,border-color,box-shadow] " <>
        "duration-productive ease-productive disabled:cursor-not-allowed disabled:border-transparent " <>
        "disabled:bg-status-neutral-bg disabled:text-text-disabled disabled:hover:bg-status-neutral-bg"

    variants = %{
      "primary" =>
        "border border-transparent bg-action-primary text-action-primary-ink hover:bg-action-primary-hover " <>
          "[[data-public-shell]_&]:font-bold",
      "secondary" =>
        "border border-border-control bg-surface-raised text-text-primary hover:bg-hover " <>
          "[[data-public-shell]_&]:font-semibold",
      "ghost" =>
        "border border-transparent bg-transparent text-interactive-strong hover:bg-interactive-tint " <>
          "[[data-public-shell]_&]:h-auto [[data-public-shell]_&]:min-h-0 [[data-public-shell]_&]:rounded-none " <>
          "[[data-public-shell]_&]:border-0 [[data-public-shell]_&]:border-b-2 " <>
          "[[data-public-shell]_&]:border-interactive-primary [[data-public-shell]_&]:bg-transparent " <>
          "[[data-public-shell]_&]:px-0 [[data-public-shell]_&]:pb-px [[data-public-shell]_&]:font-semibold " <>
          "[[data-public-shell]_&]:text-text-primary [[data-public-shell]_&]:hover:bg-transparent",
      "destructive" =>
        "border border-status-error-border bg-surface-raised text-status-error-ink hover:bg-status-error-bg",
      "destructive-solid" =>
        "border border-status-error bg-status-error text-destructive-ink " <>
          "hover:border-status-error-ink hover:bg-status-error-ink",
      nil => "border border-border-control bg-surface-raised text-text-primary hover:bg-hover"
    }

    # Always apply base + variant, then append the caller's `class` (margins,
    # width, etc.). Never let a passed `class` replace the button styling —
    # that silently renders an unstyled `<button>` (a passed `w-full` used to
    # wipe the height, fill, and padding).
    assigns =
      assign(assigns, :class, [
        base,
        if(assigns.icon_only, do: "w-control-md p-0", else: "px-4"),
        Map.fetch!(variants, assigns[:variant]),
        assigns[:class]
      ])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values; pass
      `appearance="toggle"` for the pill switch instead of the check box

    * `type="radio"` renders a single radio control (the group's shared
      `name` and each option's `checked` state are the caller's job)

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  Label sits above the control, helper text (`helper`) below it. An error
  swaps the label and message to the status-error ink, thickens the border,
  and prefixes the message with "✕" (mock 09 "FORMS — STATES").

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" helper="Shown in alerts and on the status page." />
  <.input name="my-input" errors={["oh no!"]} />
  <.input type="checkbox" appearance="toggle" field={@form[:active]} label="Active" />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :helper, :string, default: nil, doc: "helper text rendered below the control"
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox radio color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :appearance, :string,
    default: "checkbox",
    values: ~w(checkbox toggle),
    doc: "type=\"checkbox\" only: the check box or the pill toggle switch"

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox/radio inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include:
      ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step autofocus aria-describedby)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox", appearance: "toggle"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)
      |> assign_input_a11y()

    ~H"""
    <div class="mb-3">
      <label
        for={@id}
        class="inline-flex min-h-target-min items-center gap-2.5 text-label text-text-primary"
      >
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="relative inline-flex h-[17px] w-[30px] shrink-0">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "peer sr-only"}
            aria-invalid={@errors != [] && "true"}
            aria-describedby={@error_id}
            {@rest}
          />
          <span
            aria-hidden="true"
            class="pointer-events-none absolute inset-0 rounded-dot bg-status-neutral-bg transition-colors duration-productive peer-checked:bg-status-live peer-focus-visible:outline peer-focus-visible:outline-2 peer-focus-visible:outline-offset-2 peer-focus-visible:outline-focus peer-disabled:opacity-60"
          />
          <span
            aria-hidden="true"
            class="pointer-events-none absolute left-[2px] top-[2px] size-[13px] rounded-dot bg-surface-raised shadow-frame transition-transform duration-productive peer-checked:translate-x-[13px]"
          />
        </span>
        {@label}
      </label>
      <.input_errors id={@error_id} errors={@errors} />
    </div>
    """
  end

  def input(%{type: "checkbox", multiple: true} = assigns) do
    assigns = assign_input_a11y(assigns)

    ~H"""
    <div class="mb-3">
      <label for={@id} class="flex min-h-target-min items-center gap-2 text-label text-text-primary">
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value={@value}
          checked={@checked}
          class={@class || checkbox_input_class()}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@error_id}
          {@rest}
        />
        {@label}
      </label>
      <.input_errors id={@error_id} errors={@errors} />
    </div>
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)
      |> assign_input_a11y()

    ~H"""
    <div class="mb-3">
      <label for={@id} class="flex min-h-target-min items-center gap-2 text-label text-text-primary">
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={@class || checkbox_input_class()}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@error_id}
          {@rest}
        />
        {@label}
      </label>
      <.input_errors id={@error_id} errors={@errors} />
    </div>
    """
  end

  def input(%{type: "radio"} = assigns) do
    assigns = assign_input_a11y(assigns)

    ~H"""
    <div class="mb-3">
      <label for={@id} class="flex min-h-target-min items-center gap-2 text-label text-text-primary">
        <input
          type="radio"
          id={@id}
          name={@name}
          value={@value}
          checked={@checked}
          class={[
            @class ||
              "size-[15px] shrink-0 appearance-none rounded-dot border-[1.5px] border-border-control " <>
                "bg-surface-raised checked:border-[4.5px] checked:border-text-primary " <>
                "disabled:cursor-not-allowed disabled:border-border-default disabled:bg-surface-sunken"
          ]}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@error_id}
          {@rest}
        />
        {@label}
      </label>
      <.input_errors id={@error_id} errors={@errors} />
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    assigns = assign_input_a11y(assigns)

    ~H"""
    <div class="mb-3">
      <label for={@id}>
        <span :if={@label} class={label_class(@errors)}>{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[
            @class || input_class(@errors),
            @errors != [] && (@error_class || input_error_class())
          ]}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@error_id}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.input_helper helper={@helper} />
      <.input_errors id={@error_id} errors={@errors} />
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    assigns = assign_input_a11y(assigns)

    ~H"""
    <div class="mb-3">
      <label for={@id}>
        <span :if={@label} class={label_class(@errors)}>{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || [input_class(@errors), "h-auto min-h-24 py-2"],
            @errors != [] && (@error_class || input_error_class())
          ]}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@error_id}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.input_helper helper={@helper} />
      <.input_errors id={@error_id} errors={@errors} />
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    assigns = assign_input_a11y(assigns)

    ~H"""
    <div class="mb-3">
      <label for={@id}>
        <span :if={@label} class={label_class(@errors)}>{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || input_class(@errors),
            @errors != [] && (@error_class || input_error_class())
          ]}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@error_id}
          {@rest}
        />
      </label>
      <.input_helper helper={@helper} />
      <.input_errors id={@error_id} errors={@errors} />
    </div>
    """
  end

  defp checkbox_input_class,
    do:
      "peer size-[15px] shrink-0 appearance-none rounded-[4px] border-[1.5px] border-border-control " <>
        "bg-surface-raised checked:border-transparent checked:bg-surface-inverse grid place-items-center " <>
        "after:content-['✓'] after:text-[10px] after:font-bold after:leading-none after:text-transparent " <>
        "checked:after:text-interactive-primary disabled:cursor-not-allowed disabled:border-border-default " <>
        "disabled:bg-surface-sunken"

  defp label_class([]), do: "mb-1.5 block text-label text-text-primary"
  defp label_class(_errors), do: "mb-1.5 block text-label text-status-error-ink"

  defp input_class(_errors),
    do:
      "block h-control-md w-full rounded-control border border-border-control " <>
        "bg-surface-raised px-3 text-body text-text-primary placeholder:text-text-tertiary " <>
        "disabled:cursor-not-allowed disabled:border-border-default disabled:bg-hover " <>
        "disabled:text-text-disabled disabled:placeholder:text-text-disabled"

  defp input_error_class, do: "border-[1.5px] border-status-error"

  defp assign_input_a11y(assigns) do
    error_id =
      if assigns[:id] && assigns[:errors] != [] do
        "#{assigns.id}-error"
      end

    assign(assigns, :error_id, error_id)
  end

  attr :helper, :string, required: true

  defp input_helper(assigns) do
    ~H"""
    <p :if={@helper} class="mt-1.5 text-body text-text-secondary">{@helper}</p>
    """
  end

  # A single described-by region keeps multiple messages valid HTML and gives
  # every visible control one stable target for assistive technology.
  defp input_errors(assigns) do
    ~H"""
    <div
      :if={@errors != []}
      id={@id}
      role="alert"
      class="mt-1.5 space-y-1 text-label font-medium text-status-error-ink"
    >
      <p :for={message <- @errors} class="flex items-start gap-1.5">
        <span aria-hidden="true">✕</span>
        <span>{message}</span>
      </p>
    </div>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[
      @actions != [] && "flex items-center justify-between gap-6",
      "border-b border-border-default pb-4"
    ]}>
      <div>
        <h1 class="text-heading-01 text-text-primary">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-1 text-body text-text-secondary">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="shrink-0">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling: hairline rules, mono uppercase-ish
  column labels, tabular figures, and a row hover wash. Below the `md`
  breakpoint each row pivots to a key/value stack (mock 09 "TABLES") — the
  header row hides and each cell grows its own `data-label` caption from the
  column's `:label`, so the semantics stay a real `<table>` at every width.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"
  attr :density, :string, default: "comfortable", values: ~w(comfortable dense)

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table data-density={@density} class="w-full border-collapse text-left text-body max-md:block">
      <thead class="max-md:hidden">
        <tr class="border-b border-border-default">
          <th
            :for={col <- @col}
            scope="col"
            class="min-h-row px-4 py-3 text-eyebrow uppercase tracking-wide text-text-tertiary"
          >
            {col[:label]}
          </th>
          <th :if={@action != []} scope="col" class="min-h-row px-4 py-3">
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody
        id={@id}
        phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}
        class="divide-y divide-border-default max-md:block"
      >
        <tr
          :for={row <- @rows}
          id={@row_id && @row_id.(row)}
          class="hover:bg-hover max-md:flex max-md:flex-col max-md:gap-0.5 max-md:py-3"
        >
          <td
            :for={{col, index} <- Enum.with_index(@col)}
            data-label={col[:label]}
            class={[
              "min-h-row px-4 py-3 tabular-nums text-text-primary",
              "max-md:flex max-md:min-h-0 max-md:items-baseline max-md:justify-between max-md:gap-3 max-md:px-4 max-md:py-1",
              "max-md:before:shrink-0 max-md:before:font-mono max-md:before:text-eyebrow max-md:before:uppercase",
              "max-md:before:tracking-wide max-md:before:text-text-tertiary max-md:before:content-[attr(data-label)]"
            ]}
          >
            <button
              :if={is_function(@row_click, 1) and index == 0}
              type="button"
              phx-click={@row_click.(row)}
              class="min-h-target-min text-left font-medium text-text-primary hover:text-interactive-strong hover:underline focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
            >
              {render_slot(col, @row_item.(row))}
            </button>
            <span :if={not (is_function(@row_click, 1) and index == 0)}>
              {render_slot(col, @row_item.(row))}
            </span>
          </td>
          <td
            :if={@action != []}
            class="w-0 min-h-row px-4 py-3 font-medium max-md:w-auto max-md:px-4 max-md:py-2"
          >
            <div class="flex min-h-target-min items-center justify-end gap-3 max-md:justify-start">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="divide-y divide-border-default">
      <li :for={item <- @item} class="min-h-row py-3">
        <div class="text-label font-semibold text-text-tertiary">{item.title}</div>
        <div class="text-body text-text-primary">{render_slot(item)}</div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a skeleton placeholder, used instead of a full-page spinner while a
  region's data is still loading (ARCHITECTURE.md §9). Never wrap a whole
  page in one — scope it to the region that is actually loading.

  ## Examples

      <.skeleton :if={@loading} rows={3} />
  """
  attr :rows, :integer, default: 3
  attr :class, :any, default: nil
  attr :id, :string, default: nil

  def skeleton(assigns) do
    ~H"""
    <div id={@id} class={["space-y-2", @class]} aria-hidden="true" data-loading="static">
      <div :for={_ <- 1..@rows} class="h-control-md bg-surface-sunken" />
    </div>
    """
  end

  @doc """
  Renders a scoped error boundary: a region-level message with a retry
  action, in place of the region's normal content (ARCHITECTURE.md §9).
  Never a full-page error — the rest of the shell (nav, other regions)
  keeps working.

  ## Examples

      <.error_boundary :if={@load_failed?} id="projects-error" retry="retry_projects">
        Could not load projects.
      </.error_boundary>
  """
  attr :id, :string, required: true
  attr :retry, :string, default: nil, doc: "the phx-click event name for the retry button"
  slot :inner_block, required: true

  def error_boundary(assigns) do
    ~H"""
    <div
      id={@id}
      role="alert"
      class="flex flex-wrap items-center justify-between gap-3 rounded-structural border border-status-error-border bg-status-error-bg p-4 text-body text-status-error-ink"
    >
      <div class="flex items-center gap-2">
        <span class="size-2 shrink-0 rounded-dot bg-status-error" aria-hidden="true"></span>
        <span>{render_slot(@inner_block)}</span>
      </div>
      <button
        :if={@retry}
        type="button"
        phx-click={@retry}
        class="h-control-md shrink-0 rounded-control border border-status-error-border bg-surface-raised px-3 font-medium hover:bg-status-error-bg focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
      >
        Retry
      </button>
    </div>
    """
  end

  @doc """
  A copy-to-clipboard button for a value shown elsewhere on the page
  (setup snippets, endpoints, keys — ARCHITECTURE.md §9, no full-page
  spinners doc rule: give a control-scoped affordance, not a manual
  select-all). Reads the target element's text client-side; the value
  never round-trips through the server or gets duplicated into a second
  HEEx literal that could drift from what is actually shown.

  ## Examples

      <code id="ingest-endpoint">POST https://postdeploy.dev/e/errors</code>
      <.copy_button target="ingest-endpoint" />
  """
  attr :target, :string, required: true, doc: "the DOM id of the element holding the text to copy"
  attr :label, :string, default: "Copy"
  attr :id, :string, doc: "defaults to \"copy-\#{target}\""
  attr :class, :any, default: nil
  attr :size, :string, default: "sm", values: ~w(sm md), doc: "sm is compact; md matches .button"
  attr :liveview, :boolean, default: true, doc: "whether LiveView owns the copy behavior"

  attr :tone, :string,
    default: "default",
    values: ~w(default inverse),
    doc: "inverse sits on an ink surface"

  def copy_button(assigns) do
    assigns = assign_new(assigns, :id, fn -> "copy-#{assigns.target}" end)

    ~H"""
    <button
      type="button"
      id={@id}
      phx-hook={@liveview && "AlplusWeb.CoreComponents.CopyButton"}
      phx-update={@liveview && "ignore"}
      data-target={@target}
      data-copy-fallback="textarea"
      class={[
        "inline-flex h-control-md shrink-0 cursor-pointer items-center justify-center gap-1.5 rounded-control border font-semibold transition-colors duration-productive",
        @tone == "default" &&
          "border-border-default bg-surface-raised text-text-secondary hover:bg-interactive-tint hover:text-text-primary",
        @tone == "inverse" &&
          "border-border-inverse bg-transparent text-text-inverse hover:bg-surface-inverse-raised",
        @size == "md" && "h-control-md px-4 text-label",
        @size == "sm" && "h-control-md px-3 text-label",
        @class
      ]}
    >
      <.icon name="hero-clipboard-document" class="size-3.5" />
      <span id={"#{@id}-label"} data-copy-label aria-live="polite">{@label}</span>
    </button>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyButton">
      export default {
        mounted() {
          this.el.addEventListener("click", async () => {
            const target = document.getElementById(this.el.dataset.target)
            if (!target) return

            const text = target.innerText || target.textContent || ""
            const label = this.el.querySelector("[data-copy-label]")
            if (!label) return
            const original = label.textContent

            try {
              await this.copy(text)
              label.textContent = "Copied"
            } catch (_error) {
              label.textContent = "Copy failed"
            }

            window.clearTimeout(this.restoreTimer)
            this.restoreTimer = window.setTimeout(() => { label.textContent = original }, 1500)
          })
        },
        copy(text) {
          const fallback = () => {
            const textarea = document.createElement("textarea")
            textarea.value = text
            textarea.setAttribute("readonly", "")
            textarea.style.position = "fixed"
            textarea.style.opacity = "0"
            document.body.appendChild(textarea)
            textarea.select()

            try {
              if (!document.execCommand("copy")) throw new Error("Copy command rejected")
            } finally {
              textarea.remove()
            }
          }

          if (navigator.clipboard && typeof navigator.clipboard.writeText === "function") {
            return navigator.clipboard.writeText(text).catch(() => fallback())
          }

          return fallback()
        },
        destroyed() {
          window.clearTimeout(this.restoreTimer)
        }
      }
    </script>
    """
  end

  @doc """
  A modal dialog, on the platform's own `<dialog>` element.

  Native `showModal()` supplies the parts a hand-rolled overlay gets wrong:
  focus moves into the dialog and is trapped there, Escape closes it, the rest
  of the page becomes inert, and the backdrop is a real `::backdrop`
  pseudo-element instead of a stacking-context fight. The colocated hook only
  reconciles the element's open state with the caller's assign, and reports a
  dismissal back so server state cannot drift from what the operator sees.

  `docs/DESIGN-SYSTEM.md`'s standing advice is to exhaust inline and
  progressive alternatives first — a modal that could have been a section
  usually should have been. Use this when the content is a genuine detour from
  the task (reviewing invoices mid-billing-review), not to hold a form the page
  had room for.

  The dialog stays in the DOM while closed, so its contents are always
  rendered. Keep them cheap, or gate the slot on the same assign as `open`.

  ## Examples

      <.modal id="invoices" open={@show_invoices} on_close="hide_invoices" title="Invoices">
        ...
        <:actions><.button phx-click="hide_invoices">Close</.button></:actions>
      </.modal>
  """
  attr :id, :string, required: true
  attr :open, :boolean, default: false
  attr :title, :string, required: true
  attr :description, :string, default: nil

  attr :on_close, :string,
    required: true,
    doc: "event pushed when the operator dismisses the dialog (Escape, backdrop, close button)"

  slot :inner_block, required: true
  slot :actions, doc: "trailing controls in the dialog footer"

  def modal(assigns) do
    ~H"""
    <%!-- Two things here are load-bearing and easy to break.

          Centring is declared, not inherited: the UA stylesheet centres a
          modal `<dialog>` with `inset: 0` plus `margin: auto`, and Tailwind's
          preflight resets `margin` to 0, which pinned the dialog to the
          viewport's top-left corner.

          The flex column is `open:flex`, never a bare `flex`. A closed
          `<dialog>` is hidden by the UA rule `dialog:not([open]) { display:
          none }`, and an author-level `display: flex` beats a UA rule
          regardless of specificity — a bare `flex` here left the dialog
          permanently on screen. --%>
    <dialog
      id={@id}
      phx-hook=".Modal"
      data-open={to_string(@open)}
      data-close-event={@on_close}
      aria-labelledby={"#{@id}-title"}
      aria-describedby={@description && "#{@id}-description"}
      class="fixed inset-0 m-auto h-fit max-h-[calc(100dvh-2rem)] w-[calc(100vw-2rem)] max-w-3xl flex-col rounded-structural border border-border-default bg-surface-raised p-0 text-text-primary shadow-modal backdrop:bg-surface-inverse/40 open:flex"
    >
      <div class="flex shrink-0 items-start justify-between gap-4 border-b border-border-default px-5 py-4">
        <div class="min-w-0">
          <h2 id={"#{@id}-title"} class="text-body-long font-semibold text-text-primary">{@title}</h2>
          <p :if={@description} id={"#{@id}-description"} class="mt-0.5 text-body text-text-secondary">
            {@description}
          </p>
        </div>
        <button
          type="button"
          id={"#{@id}-close"}
          phx-click={@on_close}
          aria-label="Close"
          class="flex h-control-md w-control-md shrink-0 cursor-pointer items-center justify-center rounded-control text-text-tertiary transition-colors duration-productive ease-productive hover:bg-interactive-tint hover:text-text-primary"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>

      <%!-- Only the body scrolls, so the title and the footer actions stay
            reachable however long the content runs. --%>
      <div class="min-h-0 flex-1 overflow-y-auto">{render_slot(@inner_block)}</div>

      <div
        :if={@actions != []}
        class="flex shrink-0 flex-wrap items-center justify-end gap-2 border-t border-border-default px-5 py-4"
      >
        {render_slot(@actions)}
      </div>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Modal">
      export default {
        mounted() {
          // A dismissal can come from Escape or the backdrop, neither of which
          // routes through a phx-click, so both are reported back to the
          // server. The guard stops the echo when the server closed it first.
          this.el.addEventListener("close", () => {
            if (this.el.dataset.open === "true") {
              this.pushEvent(this.el.dataset.closeEvent)
            }
          })

          // `showModal()` centres the dialog in the viewport, so a click on the
          // dialog element itself landed outside its own content box: that is
          // the backdrop.
          this.el.addEventListener("click", (event) => {
            if (event.target === this.el) this.el.close()
          })

          this.sync()
        },

        updated() {
          this.sync()
        },

        sync() {
          const open = this.el.dataset.open === "true"

          if (open && !this.el.open) this.el.showModal()
          if (!open && this.el.open) this.el.close()
        }
      }
    </script>
    """
  end

  @doc """
  A timestamp rendered as elapsed time, with the exact instant kept on the
  element rather than dropped.

  Console tables show *when* something happened relative to now, because
  "3h ago" is the question an operator is actually asking. The absolute
  instant still matters when they need to correlate with a log, so it stays
  reachable two ways that cost no layout: the `datetime` attribute (machine
  readable) and the native tooltip, which is also the accessible name.

  Renders nothing for a `nil` timestamp rather than an em dash, so a caller
  decides what a missing time looks like in its own column.

  `AlplusWeb.Observe.Evidence.relative_time/2` is the Observe pillar's own
  string formatter and keeps its own, longer thresholds. This component is
  the console-wide markup version; the two are deliberately not merged,
  because Evidence returns a bare string that Observe embeds in its own
  `<time>` markup with a second absolute line below it.

  ## Examples

      <.timestamp at={log.inserted_at} />
      <.timestamp at={invoice.period_end} class="text-text-tertiary" />
  """
  attr :at, :any, required: true, doc: "a DateTime, NaiveDateTime, or nil"
  attr :class, :any, default: nil

  attr :format, :atom,
    default: :elapsed,
    values: [:elapsed, :date],
    doc: "`:date` renders the calendar date instead of elapsed time"

  def timestamp(%{at: nil} = assigns), do: ~H""

  def timestamp(assigns) do
    assigns =
      assigns
      |> assign(:absolute, absolute_time(assigns.at))
      |> assign(:machine, machine_time(assigns.at))
      |> assign(:label, timestamp_label(assigns.format, assigns.at))

    ~H"""
    <time datetime={@machine} title={@absolute} aria-label={@absolute} class={@class}>
      {@label}
    </time>
    """
  end

  # A renewal date and an invoice period are calendar facts an operator
  # reconciles against a statement, so "in 23 days" is the wrong frame for
  # them even though the markup is the same.
  defp timestamp_label(:date, at), do: Calendar.strftime(at, "%d %b %Y")
  defp timestamp_label(:elapsed, at), do: elapsed_time(at)

  defp machine_time(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp machine_time(%NaiveDateTime{} = at), do: NaiveDateTime.to_iso8601(at)

  defp absolute_time(at), do: Calendar.strftime(at, "%d %b %Y, %H:%M UTC")

  # Whole units only, one unit deep: an operator scanning a column wants the
  # magnitude, not "3h 14m 22s". Past a week the elapsed form stops being
  # useful, so it hands over to the calendar date.
  defp elapsed_time(at) do
    case DateTime.diff(DateTime.utc_now(), to_utc(at), :second) do
      seconds when seconds < 0 -> Calendar.strftime(at, "%d %b %Y")
      seconds when seconds < 60 -> "just now"
      seconds when seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds when seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      seconds when seconds < 604_800 -> "#{div(seconds, 86_400)}d ago"
      _older -> Calendar.strftime(at, "%d %b %Y")
    end
  end

  defp to_utc(%DateTime{} = at), do: at
  defp to_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"
  attr :label, :string, default: nil, doc: "accessible name when the icon carries meaning"
  attr :rest, :global

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span
      class={[@name, @class]}
      role={@label && "img"}
      aria-label={@label}
      aria-hidden={if @label, do: nil, else: "true"}
      {@rest}
    />
    """
  end

  @doc """
  Renders a keyboard-operable tab list from generic `%{id: ..., label: ...}`
  maps (or `{id, label}` tuples). The active item is exposed with
  `aria-selected`, each tab gets deterministic `id` and `aria-controls`
  attributes, and a caller-provided event receives the selected id as `tab`.
  Pass `panel_id` when the controlled panel has a caller-owned id; otherwise
  the component derives one from its own id. Pass `disabled: true` on an item
  for an unavailable tab.
  """
  attr :id, :string, required: true
  attr :tabs, :list, required: true
  attr :active, :any, default: nil
  attr :on_change, :string, required: true, doc: "the phx-click event for selecting a tab"
  attr :aria_label, :string, default: "Sections"
  attr :class, :any, default: nil
  attr :rest, :global

  def tabs(assigns) do
    tabs =
      assigns.tabs
      |> normalize_tabs!()
      |> Enum.map(fn tab ->
        %{
          tab
          | tab_id: tab.tab_id || "#{assigns.id}-tab-#{tab.id}",
            panel_id: tab.panel_id || "#{assigns.id}-panel-#{tab.id}"
        }
      end)

    validate_tabs_event!(assigns.on_change)

    requested_active = assigns.active || Enum.find_value(tabs, &(&1.selected && &1.id))

    active =
      Enum.find_value(tabs, fn tab ->
        (not tab.disabled and requested_active) && to_string(requested_active) == tab.id && tab.id
      end) || Enum.find_value(tabs, &(!&1.disabled && &1.id))

    if is_nil(active) do
      raise ArgumentError, "tabs/1 requires at least one enabled tab"
    end

    assigns =
      assigns
      |> assign(:tabs, tabs)
      |> assign(:active_tab, active && to_string(active))

    ~H"""
    <nav
      id={@id}
      role="tablist"
      aria-label={@aria_label}
      aria-orientation="horizontal"
      data-state="ready"
      data-tabs-keyboard="ArrowLeft ArrowRight Home End"
      phx-hook=".Tabs"
      class={[@class]}
      {@rest}
    >
      <button
        :for={tab <- @tabs}
        id={tab.tab_id}
        type="button"
        role="tab"
        aria-selected={if(to_string(tab.id) == @active_tab, do: "true", else: "false")}
        aria-controls={tab.panel_id}
        tabindex={if(to_string(tab.id) == @active_tab, do: "0", else: "-1")}
        disabled={tab.disabled}
        phx-click={@on_change}
        phx-value-tab={tab.id}
        class={[
          "h-control-md px-3 text-label transition-[box-shadow,color] duration-productive focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus",
          if(to_string(tab.id) == @active_tab,
            do:
              "font-semibold text-text-primary shadow-[inset_0_-2px_0_var(--color-interactive-primary)]",
            else:
              "font-medium text-text-secondary shadow-[inset_0_-2px_0_transparent] hover:text-text-primary"
          ),
          tab.disabled && "cursor-not-allowed text-text-disabled"
        ]}
      >
        {tab.label}
      </button>
    </nav>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Tabs">
      export default {
        mounted() {
          this.handleKeydown = event => {
            if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return

            const tabs = Array.from(this.el.querySelectorAll('[role="tab"]'))
              .filter(tab => !tab.disabled)
            if (!tabs.length) return

            const current = tabs.indexOf(event.target.closest('[role="tab"]'))
            const index = current < 0 ? 0 : current
            let next

            if (event.key === "Home") next = 0
            else if (event.key === "End") next = tabs.length - 1
            else {
              const step = event.key === "ArrowRight" ? 1 : -1
              next = (index + step + tabs.length) % tabs.length
            }

            event.preventDefault()
            tabs[next].focus()
            tabs[next].click()
          }

          this.el.addEventListener("keydown", this.handleKeydown)
        },
        destroyed() {
          this.el.removeEventListener("keydown", this.handleKeydown)
        }
      }
    </script>
    """
  end

  defp validate_tabs_event!(event) when is_binary(event) do
    if String.trim(event) == "" do
      raise ArgumentError, "tabs/1 requires a non-empty on_change event"
    end
  end

  defp validate_tabs_event!(_event),
    do: raise(ArgumentError, "tabs/1 requires a non-empty on_change event")

  @doc """
  Renders mono page controls with semantic navigation, selected-page state,
  and disabled previous/next controls at either boundary. Use `on_change` for
  LiveView events or `path` for ordinary links; exactly one mechanism is
  required, and page numbers remain visible in either mode.
  """
  attr :id, :string, required: true
  attr :current_page, :integer, default: nil
  attr :page, :integer, default: nil, doc: "alias for current_page"
  attr :total_pages, :integer, required: true
  attr :on_change, :string, default: nil
  attr :path, :string, default: nil
  attr :page_param, :string, default: "page"
  attr :aria_label, :string, default: "Pagination"
  attr :class, :any, default: nil
  attr :rest, :global

  def pagination(assigns) do
    path? = is_binary(assigns.path) and String.trim(assigns.path) != ""
    on_change? = is_binary(assigns.on_change) and String.trim(assigns.on_change) != ""

    if path? == on_change? do
      raise ArgumentError, "pagination/1 requires exactly one of path or on_change"
    end

    current_page = assigns.current_page || assigns.page || 1

    if not is_integer(current_page) or not is_integer(assigns.total_pages) or
         current_page < 1 or current_page > assigns.total_pages or assigns.total_pages < 1 do
      raise ArgumentError, "pagination/1 requires a page between 1 and total_pages"
    end

    assigns =
      assigns
      |> assign(:current_page, current_page)
      |> assign(:path, if(path?, do: assigns.path, else: nil))
      |> assign(:on_change, if(on_change?, do: assigns.on_change, else: nil))
      |> assign(:pages, Enum.to_list(1..assigns.total_pages))

    ~H"""
    <nav id={@id} role="navigation" aria-label={@aria_label} class={[@class]} {@rest}>
      <div class="flex flex-wrap items-center gap-1">
        <.pagination_control
          id={"#{@id}-previous"}
          page={@current_page - 1}
          label="Previous"
          disabled={@current_page == 1}
          on_change={@on_change}
          path={@path}
          page_param={@page_param}
        />
        <%= for page <- @pages do %>
          <.pagination_control
            id={"#{@id}-page-#{page}"}
            page={page}
            label={Integer.to_string(page)}
            current={page == @current_page}
            disabled={false}
            on_change={@on_change}
            path={@path}
            page_param={@page_param}
          />
        <% end %>
        <.pagination_control
          id={"#{@id}-next"}
          page={@current_page + 1}
          label="Next"
          disabled={@current_page == @total_pages}
          on_change={@on_change}
          path={@path}
          page_param={@page_param}
        />
      </div>
    </nav>
    """
  end

  attr :id, :string, required: true
  attr :page, :integer, required: true
  attr :label, :string, required: true
  attr :current, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :on_change, :string, default: nil
  attr :path, :string, default: nil
  attr :page_param, :string, default: "page"

  defp pagination_control(assigns) do
    ~H"""
    <%= if @path && is_nil(@on_change) do %>
      <a
        id={@id}
        href={if(@disabled, do: nil, else: pagination_href(@path, @page_param, @page))}
        aria-current={@current && "page"}
        class={pagination_control_class(@current, @disabled)}
        aria-disabled={@disabled && "true"}
        tabindex={@disabled && "-1"}
      >
        {@label}
      </a>
    <% else %>
      <button
        id={@id}
        type="button"
        phx-click={@on_change}
        phx-value-page={@page}
        aria-current={@current && "page"}
        disabled={@disabled}
        class={pagination_control_class(@current, @disabled)}
      >
        {@label}
      </button>
    <% end %>
    """
  end

  defp pagination_control_class(current, disabled) do
    [
      "inline-flex h-control-md w-control-md items-center justify-center rounded-control-sm border font-mono text-data",
      if(current,
        do: "border-border-strong bg-surface-raised font-medium text-text-primary",
        else: "border-border-default bg-surface-raised text-text-secondary hover:bg-hover"
      ),
      disabled && "cursor-not-allowed border-transparent bg-status-neutral-bg text-text-disabled"
    ]
  end

  defp pagination_href(path, page_param, page) do
    separator = if String.contains?(path, "?"), do: "&", else: "?"
    path <> separator <> URI.encode_query(%{page_param => page})
  end

  @doc """
  Renders an inline status alert. `kind` accepts live/success, late/warning,
  error, paused, and neutral/info aliases; each state has a visible icon and
  state-colored rule. Supply `message` or the inner block for the content.
  """
  attr :id, :string, default: nil

  attr :kind, :string,
    default: "neutral",
    values: ~w(live success late warning error paused neutral info)

  attr :title, :string, default: nil
  attr :message, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block

  def alert(assigns) do
    inner_block = Map.get(assigns, :inner_block, [])
    kind = Map.fetch!(assigns, :kind)
    message = Map.get(assigns, :message) || (inner_block == [] && alert_kind_label(kind))

    assigns =
      assigns
      |> assign(:message, message)
      |> assign(:inner_block, inner_block)
      |> assign(:has_inner_block, inner_block != [])
      |> assign(
        :alert_role,
        if(kind == "error", do: "alert", else: "status")
      )
      |> assign(
        :alert_live,
        if(kind == "error", do: "assertive", else: "polite")
      )

    ~H"""
    <div
      id={@id}
      role={@alert_role}
      aria-live={@alert_live}
      data-kind={@kind}
      class={[
        "flex items-start gap-3 rounded-control border border-l-[3px] bg-surface-raised p-4 text-body",
        alert_tone_class(@kind),
        @class
      ]}
      {@rest}
    >
      <.icon name={alert_icon(@kind)} class={["mt-0.5 size-5 shrink-0", alert_icon_class(@kind)]} />
      <div class="min-w-0">
        <p :if={@title} class={["font-semibold", alert_icon_class(@kind)]}>{@title}</p>
        <p :if={@message} class="text-text-secondary">{@message}</p>
        <div :if={@has_inner_block} class="text-text-secondary">{render_slot(@inner_block)}</div>
      </div>
    </div>
    """
  end

  defp alert_icon(kind) when kind in ["live", "success"], do: "hero-check-circle"
  defp alert_icon(kind) when kind in ["late", "warning"], do: "hero-exclamation-triangle"
  defp alert_icon("error"), do: "hero-x-circle"
  defp alert_icon("paused"), do: "hero-pause-circle"
  defp alert_icon(_neutral), do: "hero-information-circle"

  defp alert_icon_class(kind) when kind in ["live", "success"], do: "text-status-live-ink"
  defp alert_icon_class(kind) when kind in ["late", "warning"], do: "text-status-late-ink"
  defp alert_icon_class("error"), do: "text-status-error-ink"
  defp alert_icon_class("paused"), do: "text-status-paused-ink"
  defp alert_icon_class(_neutral), do: "text-status-neutral-ink"

  defp alert_tone_class(kind) when kind in ["live", "success"],
    do: "border-status-live-border border-l-status-live"

  defp alert_tone_class(kind) when kind in ["late", "warning"],
    do: "border-status-late-border border-l-status-late"

  defp alert_tone_class("error"), do: "border-status-error-border border-l-status-error"
  defp alert_tone_class("paused"), do: "border-status-paused-border border-l-status-paused"
  defp alert_tone_class(_neutral), do: "border-status-neutral-border border-l-status-neutral"

  defp alert_kind_label(kind) when kind in ["live", "success"], do: "Live update"
  defp alert_kind_label(kind) when kind in ["late", "warning"], do: "Warning update"
  defp alert_kind_label("error"), do: "Error update"
  defp alert_kind_label("paused"), do: "Paused update"
  defp alert_kind_label(_neutral), do: "Information update"

  @doc """
  Renders the ruled article shell used by documentation and changelog pages.
  The body is generic content; optional eyebrow, metadata, description, and
  aside slots keep the layout independent of a domain struct.
  """
  attr :id, :string, default: nil
  attr :title, :string, default: nil
  attr :description, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :eyebrow
  slot :meta
  slot :inner_block, required: true
  slot :aside

  def article_layout(assigns) do
    ~H"""
    <article id={@id} class={["border-t border-border-default", @class]} {@rest}>
      <header
        :if={@title || @description || @eyebrow != [] || @meta != []}
        class="border-b border-border-default py-6"
      >
        <p
          :if={@eyebrow != []}
          class="text-label font-semibold uppercase tracking-wide text-text-tertiary"
        >
          {render_slot(@eyebrow)}
        </p>
        <h1 :if={@title} class="mt-1 text-heading-01 text-text-primary">{@title}</h1>
        <p :if={@description} class="mt-2 max-w-3xl text-body text-text-secondary">{@description}</p>
        <div :if={@meta != []} class="mt-3 text-data text-text-tertiary">{render_slot(@meta)}</div>
      </header>
      <div class={["grid gap-8 py-6", @aside != [] && "lg:grid-cols-[minmax(0,1fr)_16rem]"]}>
        <div class="min-w-0">{render_slot(@inner_block)}</div>
        <aside :if={@aside != []} class="min-w-0">{render_slot(@aside)}</aside>
      </div>
    </article>
    """
  end

  @doc """
  Renders an inverse code panel with a mono filename/language header and a
  hook-owned copy control targeting the stable code element id.
  """
  attr :id, :string, required: true
  attr :code, :string, default: nil
  attr :filename, :string, default: nil
  attr :language, :string, default: nil
  attr :copy_label, :string, default: "Copy"
  attr :copy, :boolean, default: true, doc: "whether to render the copy control"
  attr :liveview_copy, :boolean, default: true, doc: "whether LiveView owns the copy behavior"
  attr :wrap, :boolean, default: false, doc: "wrap long lines, for prose payloads such as prompts"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block

  def code_panel(assigns) do
    assigns = assign(assigns, :code_id, "#{assigns.id}-code")

    ~H"""
    <section
      id={@id}
      class={[
        "min-w-0 max-w-full overflow-hidden rounded-frame bg-surface-inverse text-text-inverse",
        @class
      ]}
      {@rest}
    >
      <header class="flex items-center justify-between gap-3 border-b border-border-inverse py-2 pr-2 pl-4">
        <div class="min-w-0 font-mono text-data text-text-inverse-muted">
          <span class="break-all">{@filename || "Code"}</span>
          <span :if={@language} class="ml-2">{@language}</span>
        </div>
        <.copy_button
          :if={@copy}
          id={"#{@id}-copy"}
          target={@code_id}
          label={@copy_label}
          size="sm"
          liveview={@liveview_copy}
          tone="inverse"
        />
      </header>
      <pre
        id={@code_id}
        class={[
          "overflow-x-auto p-4 text-data font-mono leading-relaxed",
          @wrap && "whitespace-pre-wrap break-words"
        ]}
        tabindex="0"
      ><code :if={@code}>{@code}</code>{render_slot(@inner_block)}</pre>
    </section>
    """
  end

  @doc """
  Renders one semantic metric label/value row. The value and optional unit are
  visible together, while `tone` provides a supplementary status treatment.
  """
  attr :id, :string, default: nil
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :unit, :string, default: nil
  attr :definition, :string, default: nil

  attr :tone, :string,
    default: "neutral",
    values: ~w(live success late warning error paused neutral)

  attr :class, :any, default: nil
  attr :rest, :global
  slot :detail

  def metric_row(assigns) do
    ~H"""
    <dl
      id={@id}
      data-tone={@tone}
      class={[
        "min-h-row border-b border-border-default py-3",
        metric_tone_class(@tone),
        @class
      ]}
      {@rest}
    >
      <div class="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-4">
        <dt class="text-label text-text-secondary">{@label}</dt>
        <dd class="text-right text-heading-02 font-semibold tabular-nums text-text-primary">
          {@value}<span :if={@unit} class="ml-1 text-label font-normal text-text-secondary">{@unit}</span>
        </dd>
        <p :if={@definition || @detail != []} class="col-span-full text-label text-text-tertiary">
          <span :if={@definition}>{@definition}</span>{render_slot(@detail)}
        </p>
      </div>
    </dl>
    """
  end

  defp metric_tone_class(kind) when kind in ["live", "success"],
    do: "border-l-2 border-status-live"

  defp metric_tone_class(kind) when kind in ["late", "warning"],
    do: "border-l-2 border-status-late"

  defp metric_tone_class("error"), do: "border-l-2 border-status-error"
  defp metric_tone_class("paused"), do: "border-l-2 border-status-paused"
  defp metric_tone_class(_neutral), do: "border-l-2 border-status-neutral"

  @doc """
  Renders an index row with a semantic title link when a destination is
  supplied. Selected, disabled, and loading/empty/error states are explicit
  attributes; non-ready states render their own semantic message/action
  content, and row clicks are never attached to a non-interactive container.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :meta, :any, default: nil

  attr :message, :string,
    default: nil,
    doc: "visible state message for empty/error/disabled/permission/unavailable rows"

  attr :href, :string, default: nil
  attr :navigate, :string, default: nil
  attr :selected, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :state, :any, default: :ready
  attr :class, :any, default: nil
  attr :rest, :global
  slot :trailing
  slot :action, doc: "retry/help/next-step controls for non-ready rows"

  def index_row(assigns) do
    requested_state = normalize_component_state!(assigns.state, "index_row")
    disabled = assigns.disabled or requested_state == "disabled"
    state = if(disabled, do: "disabled", else: requested_state)

    if state in ["empty", "error", "permission", "unavailable"] and
         (not is_binary(assigns.message) or String.trim(assigns.message) == "") do
      raise ArgumentError, "index_row/1 requires a non-empty message for #{state} state"
    end

    assigns =
      assigns
      |> assign(:state_name, state)
      |> assign(:disabled_state, disabled)

    ~H"""
    <div
      id={@id}
      data-state={@state_name}
      aria-busy={@state_name == "loading" && "true"}
      aria-current={@selected && "true"}
      aria-disabled={@disabled_state && "true"}
      class={[
        "flex min-h-row items-center justify-between gap-4 border-b border-border-default py-3",
        @selected && "border-l-2 border-interactive-strong bg-interactive-tint pl-3",
        @disabled_state && "bg-surface-sunken text-text-disabled",
        @class
      ]}
      {@rest}
    >
      <div :if={@state_name == "loading"} class="min-w-0 flex-1" role="status">
        <.skeleton rows={1} />
      </div>
      <div
        :if={@state_name == "empty"}
        class="flex min-w-0 flex-1 items-start gap-3 border-l-2 border-border-default bg-surface-sunken p-3"
        role="status"
      >
        <.icon name="hero-information-circle" class="size-5 shrink-0" />
        <div class="min-w-0">
          <p class="text-body text-text-secondary">{@message}</p>
          <div :if={@action != []} class="mt-2">{render_slot(@action)}</div>
        </div>
      </div>
      <div
        :if={@state_name == "error"}
        class="flex min-w-0 flex-1 items-start gap-3 border-l-2 border-status-error bg-status-error-bg p-3 text-status-error-ink"
        role="alert"
      >
        <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
        <div class="min-w-0">
          <p class="text-body">{@message}</p>
          <div :if={@action != []} class="mt-2">{render_slot(@action)}</div>
        </div>
      </div>
      <div
        :if={@state_name == "disabled"}
        class="flex min-w-0 flex-1 items-start gap-3 bg-surface-sunken p-3 text-text-secondary"
        role="group"
      >
        <.icon name="hero-pause-circle" class="size-5 shrink-0" />
        <p class="text-body">{@message || "Unavailable"}</p>
      </div>
      <div
        :if={@state_name in ["permission", "unavailable"]}
        class={[
          "flex min-w-0 flex-1 items-start gap-3 border-l-2 p-3 text-body",
          @state_name == "permission" &&
            "border-status-neutral-border bg-status-neutral-bg text-status-neutral-ink",
          @state_name == "unavailable" &&
            "border-status-error-border bg-status-error-bg text-status-error-ink"
        ]}
        role="status"
      >
        <.icon
          name={
            if(@state_name == "permission", do: "hero-lock-closed", else: "hero-exclamation-triangle")
          }
          class="size-5 shrink-0"
        />
        <div class="min-w-0">
          <p>{@message}</p>
          <div :if={@action != []} class="mt-2">{render_slot(@action)}</div>
        </div>
      </div>
      <div :if={@state_name == "ready"} class="min-w-0">
        <%= if @disabled_state || (is_nil(@href) && is_nil(@navigate)) do %>
          <span class="text-label font-semibold text-text-primary">{@title}</span>
        <% else %>
          <%= if @href do %>
            <.link
              href={@href}
              class="text-label font-semibold text-interactive-strong hover:underline focus-visible:outline focus-visible:outline-2 focus-visible:outline-focus"
            >{@title}</.link>
          <% else %>
            <.link
              navigate={@navigate}
              class="text-label font-semibold text-interactive-strong hover:underline focus-visible:outline focus-visible:outline-2 focus-visible:outline-focus"
            >{@title}</.link>
          <% end %>
        <% end %>
        <p :if={@description} class="mt-1 text-body text-text-secondary">{@description}</p>
        <p :if={@meta} class="mt-1 text-data text-text-tertiary">{@meta}</p>
      </div>
      <div :if={@state_name == "ready" and @trailing != []} class="shrink-0">
        {render_slot(@trailing)}
      </div>
    </div>
    """
  end

  defp normalize_component_state!(state, _component)
       when state in [:ready, :loading, :empty, :error, :disabled, :permission, :unavailable],
       do: Atom.to_string(state)

  defp normalize_component_state!(state, _component)
       when state in [
              "ready",
              "loading",
              "empty",
              "error",
              "disabled",
              "permission",
              "unavailable"
            ],
       do: state

  defp normalize_component_state!(state, component),
    do:
      raise(
        ArgumentError,
        "#{component}/1 state must be ready, loading, empty, error, disabled, permission, or unavailable; got #{inspect(state)}"
      )

  defp normalize_tabs!(tabs) when is_list(tabs) and tabs != [] do
    Enum.map(tabs, &normalize_tab!/1)
  end

  defp normalize_tabs!(_tabs), do: raise(ArgumentError, "tabs/1 requires at least one tab")

  defp normalize_tab!({id, label}) when not is_nil(id),
    do: normalize_tab!(%{id: id, label: label})

  defp normalize_tab!(tab) when is_map(tab) do
    id = Map.get(tab, :id) || Map.get(tab, "id") || Map.get(tab, :key) || Map.get(tab, "key")

    label =
      Map.get(tab, :label) || Map.get(tab, "label") || Map.get(tab, :title) ||
        Map.get(tab, "title")

    selected =
      Map.get(
        tab,
        :selected,
        Map.get(tab, "selected", Map.get(tab, :selected?, Map.get(tab, "selected?", false)))
      )

    disabled =
      Map.get(
        tab,
        :disabled,
        Map.get(tab, "disabled", Map.get(tab, :disabled?, Map.get(tab, "disabled?", false)))
      )

    panel_id = Map.get(tab, :panel_id) || Map.get(tab, "panel_id")
    tab_id = Map.get(tab, :tab_id) || Map.get(tab, "tab_id")

    if is_nil(id) or String.trim(to_string(id)) == "" or is_nil(label) or
         String.trim(to_string(label)) == "" do
      raise ArgumentError, "tabs/1 items require non-empty id and label"
    end

    id = to_string(id)

    %{
      id: id,
      label: label,
      selected: selected == true,
      disabled: disabled == true,
      tab_id: tab_id,
      panel_id: panel_id
    }
  end

  defp normalize_tab!(_tab),
    do: raise(ArgumentError, "tabs/1 items must be maps or {id, label} tuples")

  @doc """
  Renders a small inline chip: `variant="new"` for a feature-announcement
  pill (chartreuse-wash), `variant="mono"` for a machine value (a version,
  an id) in `Geist Mono` on a neutral fill (mock 09 "BADGES · STATUS ·
  KEY/VALUE").

  ## Examples

      <.chip variant="new">New</.chip>
      <.chip variant="mono">v2.4.1</.chip>
  """
  attr :variant, :string, default: "mono", values: ~w(new mono)
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def chip(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center whitespace-nowrap px-2.5 py-1 text-chip",
      @variant == "new" && "rounded-dot bg-interactive-wash font-semibold text-interactive-strong",
      @variant == "mono" &&
        "rounded-control-sm bg-status-neutral-bg font-mono font-medium text-text-secondary",
      @class
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  Renders an ink-filled tooltip on hover/focus (mock 09 "OVERLAYS"). The
  trigger is the inner block; make sure it is itself focusable (a link,
  button, or an element with `tabindex="0"`) so keyboard users reach it.

  ## Examples

      <.tooltip id="p95-tip" text="p95 480ms across 2 regions">
        <button type="button" aria-describedby="p95-tip">p95</button>
      </.tooltip>
  """
  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :placement, :string, default: "top", values: ~w(top bottom)
  slot :inner_block, required: true

  def tooltip(assigns) do
    ~H"""
    <span class="group/tooltip relative inline-flex">
      {render_slot(@inner_block)}
      <span
        id={@id}
        role="tooltip"
        class={[
          "pointer-events-none absolute left-1/2 z-50 -translate-x-1/2 whitespace-nowrap rounded-control-sm",
          "bg-surface-inverse px-2.5 py-1.5 text-tooltip text-text-inverse opacity-0 shadow-overlay",
          "transition-opacity duration-productive group-hover/tooltip:opacity-100",
          "group-focus-within/tooltip:opacity-100",
          @placement == "top" && "bottom-full mb-2",
          @placement == "bottom" && "top-full mt-2"
        ]}
      >
        {@text}
      </span>
    </span>
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 240,
      transition:
        {"transition-opacity ease-expressive duration-expressive", "opacity-0", "opacity-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 110,
      transition:
        {"transition-opacity ease-productive duration-productive", "opacity-100", "opacity-0"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(AlplusWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(AlplusWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
