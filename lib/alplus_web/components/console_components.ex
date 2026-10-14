defmodule AlplusWeb.ConsoleComponents do
  @moduledoc """
  The console UI kit: the shared, reusable pieces every `/dashboard/` page
  draws with (BUILD.md Phase 5, `docs/research/dashboard-ui-parity-plan.md`).

  Styled against the semantic PostDeploy tokens in `assets/css/alp/` only.
  Structural surfaces use 8–12px radii; console controls use 32px heights on
  pointer devices and remap to the 44px comfortable target on touch pointers.
  No default Tailwind palette, no `--alp-gray-*`.

  Design rules carried from the legacy audit:

  - Status is color **and** icon **and** text. Never color alone
    (`status_badge/1`).
  - "No data" is not "0". `empty_state/1` for a missing prerequisite; a real
    zero renders as a real zero in a `stat_card/1`.
  - A metric card states its definition (`stat_card/1` `:definition`).
  - Skeletons, not spinners, while a region loads (`CoreComponents.skeleton/1`).
  """
  use Phoenix.Component
  use Gettext, backend: AlplusWeb.Gettext

  import AlplusWeb.CoreComponents, only: [icon: 1, button: 1, input: 1, copy_button: 1]

  @doc """
  A status pill: tone + icon + text label, so color is never the only signal.

  Tones map to the token triads. Pass an explicit `icon`, or accept the
  per-tone default. `label` is required and always rendered.

  ## Examples

      <.status_badge tone="success" label="Up" />
      <.status_badge tone="error" icon="hero-x-circle" label="Down" />
      <.status_badge tone="neutral" label="Paused" />
      <.status_badge tone="success" label="Operational" size={:public} />
  """
  attr :tone, :string,
    default: "neutral",
    values: ~w(success warning error info neutral live late paused)

  attr :label, :string, required: true
  attr :icon, :string, default: nil
  attr :size, :atom, default: :md, values: [:sm, :md, :public]
  attr :class, :any, default: nil

  def status_badge(assigns) do
    assigns =
      if assigns.size == :public do
        assigns
      else
        assign_new(assigns, :resolved_icon, fn -> assigns.icon || default_icon(assigns.tone) end)
      end

    ~H"""
    <span
      role="status"
      class={[
        "relative inline-flex items-center whitespace-nowrap rounded-dot border",
        badge_size_class(@size),
        badge_tone_class(@tone, @size),
        @class
      ]}
    >
      <span
        class={[badge_dot_size_class(@size), "shrink-0 rounded-dot", badge_dot_class(@tone, @size)]}
        aria-hidden="true"
      />
      <.icon :if={@size != :public} name={@resolved_icon} class="size-3.5 shrink-0" />
      <span>{@label}</span>
    </span>
    """
  end

  defp badge_tone_class(tone, _size) when tone in ["success", "live"],
    do: "border-status-live-border bg-status-live-bg text-status-live-ink"

  defp badge_tone_class(tone, _size) when tone in ["warning", "late"],
    do: "border-status-late-border bg-status-late-bg text-status-late-ink"

  defp badge_tone_class("error", _size),
    do: "border-status-error-border bg-status-error-bg text-status-error-ink"

  defp badge_tone_class("info", :public),
    do: "border-status-info-border bg-status-info-bg text-status-info-ink"

  defp badge_tone_class(tone, _size) when tone in ["info", "neutral", "paused"],
    do: "border-status-neutral-border bg-status-neutral-bg text-status-neutral-ink"

  defp badge_tone_class(_tone, _size),
    do: "border-status-neutral-border bg-status-neutral-bg text-status-neutral-ink"

  defp badge_dot_class(tone, _size) when tone in ["success", "live"], do: "bg-status-live"
  defp badge_dot_class(tone, _size) when tone in ["warning", "late"], do: "bg-status-late"
  defp badge_dot_class("error", _size), do: "bg-status-error"
  defp badge_dot_class("info", :public), do: "bg-status-info"
  defp badge_dot_class(_tone, _size), do: "bg-status-neutral"

  defp default_icon(tone) when tone in ["success", "live"], do: "hero-check-circle"
  defp default_icon(tone) when tone in ["warning", "late"], do: "hero-exclamation-triangle"
  defp default_icon("error"), do: "hero-x-circle"
  defp default_icon("info"), do: "hero-information-circle"
  defp default_icon("paused"), do: "hero-pause-circle"
  defp default_icon(_neutral), do: "hero-minus-circle"

  defp badge_size_class(:sm), do: "gap-1 px-2 py-0.5 text-chip font-medium"
  defp badge_size_class(:public), do: "gap-2 px-3 py-1 text-[12.5px] font-semibold"
  defp badge_size_class(:md), do: "gap-1.5 px-2.5 py-1 text-label font-medium"

  defp badge_dot_size_class(:public), do: "size-[7px]"
  defp badge_dot_size_class(_size), do: "size-1.5"

  @doc """
  A metric tile: label (with an optional definition), a value, an optional
  hint or trend line. A real zero is a real value here — never faked.

  ## Examples

      <.stat_card label="Uptime" value="99.98%" definition="Time-weighted, this window." tone="success" />
      <.stat_card label="Open issues" value={@open_count} hint="last 24h" />
  """
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :definition, :string, default: nil, doc: "one-line explanation, shown on the info icon"
  attr :hint, :string, default: nil

  attr :tone, :string,
    default: "neutral",
    values: ~w(success warning error info neutral live late paused)

  attr :id, :string, default: nil
  attr :class, :string, default: nil, doc: "extra classes on the card root, e.g. layout"

  attr :placeholder, :boolean,
    default: false,
    doc: "no evidence exists yet: draw the value slot at metric scale in muted ink"

  attr :rest, :global

  slot :inner_block, doc: "optional trailing content, e.g. a sparkline"

  def stat_card(assigns) do
    ~H"""
    <div
      id={@id}
      class={["rounded-structural border border-border-default bg-surface-raised p-5", @class]}
      {@rest}
    >
      <div class="flex items-center gap-1.5">
        <%!-- Sentence case, not small caps: design source §04's tile label is
              `Geist 500 12.5px #6E7864` reading as a phrase ("Uptime, last 90
              days"), and an uppercased phrase of that length stops being a
              label and becomes a banner. --%>
        <p class="text-label font-medium text-text-secondary">{@label}</p>
        <span
          :if={@definition}
          class="inline-flex cursor-help text-text-tertiary"
          title={@definition}
          aria-label={@definition}
        >
          <.icon name="hero-information-circle" class="size-3.5" />
        </span>
      </div>
      <%!-- A tile with nothing to show still holds the shape of the number
            that will arrive: the metric slot at full size, in the metadata
            tone, with the hint saying what starts it. It reads as a value not
            yet counted, never as a disabled control, so it takes the readable
            tertiary rather than the deliberately-muted disabled ink. --%>
      <p class={[
        "mt-1.5 tabular-nums",
        if(@placeholder, do: "text-stat text-text-tertiary", else: stat_value_class(@value)),
        not @placeholder && value_tone_class(@tone)
      ]}>
        {@value}
      </p>
      <%!-- The design source draws this clause as a machine value (`1 incident,
            4 minutes`), but every real caller passes a sentence ("an agent can
            create the first check"). Prose is never mono, so the hint reads in
            the sans caption at the body tone. A caller with an actual machine
            value wraps it in `font-mono` itself. --%>
      <p :if={@hint} class="mt-1.5 text-caption text-text-secondary">{@hint}</p>
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp value_tone_class(tone) when tone in ["success", "live"], do: "text-status-live-ink"
  defp value_tone_class(tone) when tone in ["warning", "late"], do: "text-status-late-ink"
  defp value_tone_class("error"), do: "text-status-error-ink"
  defp value_tone_class(_tone), do: "text-text-primary"

  # Real measurements keep the metric scale in sans. Empty/unavailable copy
  # is a sentence at body size — never a 40px mono slot.
  defp stat_value_class(value) when is_number(value),
    do: "text-stat"

  defp stat_value_class(value) when is_binary(value) do
    if String.match?(String.trim(value), ~r/^[\+\-]?\$?\d/) do
      "text-stat"
    else
      "text-body font-normal"
    end
  end

  defp stat_value_class(_value), do: "text-body font-normal"

  @doc """
  A bordered content card with a titled header and optional actions. Cards
  are bordered, never shadowed (token rule).

  ## Examples

      <.section_card title="Install snippet">
        ...
        <:actions><.button>Copy</.button></:actions>
      </.section_card>
  """
  attr :title, :string, default: nil
  attr :description, :string, default: nil
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true
  slot :actions

  def section_card(assigns) do
    ~H"""
    <section
      id={@id}
      class={["rounded-structural border border-border-default bg-surface-raised p-5", @class]}
    >
      <%!-- Same header row as `data_panel/1`: `text-heading-03` is the panel
            title, one step above the content beneath it and one step below
            the `heading-02` a summary band uses. Wrapping, because an actions
            slot holding filter controls has to stack under the title at 390px
            instead of pushing the panel past the viewport. --%>
      <div
        :if={@title || @actions != []}
        class="mb-4 flex flex-wrap items-start justify-between gap-x-4 gap-y-3"
      >
        <div :if={@title} class="min-w-0">
          <h2 class="text-heading-03 text-text-primary">{@title}</h2>
          <p :if={@description} class="mt-1 text-body text-text-secondary">{@description}</p>
        </div>
        <div :if={@actions != []} class="flex min-w-0 flex-wrap items-center gap-2">
          {render_slot(@actions)}
        </div>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  The console's first-run card: the one shape for "this screen has no evidence
  yet, and here is the agent task that produces some".

  It is a normal left-aligned panel, not a hero. Five screens each invented
  their own version of this, three of them centring a heading above a
  left-aligned mono block inside one frame, so the reader met a different
  activation surface on every page.

  Anatomy, top to bottom:

    * a title and one sentence saying what will appear here;
    * the real agent connection state, as a label plus `status_badge/1`;
    * the agent task in a quiet sunken prompt box. The box has a fill and no
      border, because a bordered box inside this bordered card is the console's
      one hard layout ban. Mono is right here and nowhere else in the card: the
      task string is a payload handed to a machine, not prose;
    * one link, in the UI face. Never mono, never a second button.

  The copy control says **"Copy task"** on every screen in the product.

  It is a **section of a first-run screen, not the screen**. It fills the
  column it is given, so a caller puts it in the narrower arm of a `7/5` grid
  beside the structure the reader will receive once evidence arrives, or gives
  it the full width when it is genuinely the only thing to say. A screen whose
  entire body is this card, alone, in the corner of a 1440px viewport is the
  composition this component exists to prevent.

  Two states, and only two:

    * `:not_connected`, meaning nothing is configured yet, so the next move is
      to connect an agent;
    * `:awaiting_evidence`, meaning an agent is connected and nothing has
      arrived yet.

  A list filtered to zero matches is **not** this card: that is one sentence
  and a "Clear filters" link inside the `data_panel` the rows would fill. A
  read that failed is `CoreComponents.error_boundary/1`.

  ## Examples

      <.first_run_card
        id="measure-first-run"
        title="No Measure evidence yet"
        description="Pageviews and visits appear here once a site starts reporting."
        state={:not_connected}
        task="Inspect Measure traffic for this project and report whether a source is receiving pageviews."
        action_href={~p"/dashboard/orgs/.../connect"}
      />
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true

  attr :state, :atom,
    required: true,
    values: [:not_connected, :awaiting_evidence],
    doc: "the real agent connection state, never the LiveView socket's"

  attr :task, :string, required: true, doc: "the exact string the reader hands to an agent"
  attr :action_href, :string, required: true
  attr :action_label, :string, default: nil, doc: "overrides the per-state default"

  attr :class, :any, default: nil

  slot :steps,
    doc: "an optional ordered list of what happens after connecting, drawn under the task"

  def first_run_card(assigns) do
    ~H"""
    <section
      id={@id}
      class={[
        "flex w-full min-w-0 flex-col rounded-structural border border-border-default bg-surface-raised p-5",
        @class
      ]}
      aria-labelledby={"#{@id}-title"}
    >
      <%!-- The connection state is chrome, not card content: the shell's top
            bar states it once for the whole screen. The card says what to do
            next. --%>
      <h2 id={"#{@id}-title"} class="min-w-0 text-heading-02 text-text-primary">{@title}</h2>
      <p class="mt-1.5 max-w-prose text-body-long text-text-secondary">{@description}</p>

      <p class="mt-5 text-label font-medium text-text-secondary">
        Hand this to your agent
      </p>
      <div class="mt-2 flex min-w-0 flex-col gap-2 sm:flex-row sm:items-start">
        <pre
          id={"#{@id}-task"}
          class="w-full min-w-0 flex-1 whitespace-pre-wrap [overflow-wrap:anywhere] rounded-control bg-surface-sunken p-4 font-mono text-data leading-relaxed text-text-primary"
        >{@task}</pre>
        <.copy_button target={"#{@id}-task"} label="Copy task" />
      </div>

      <div :if={@steps != []} class="mt-5">{render_slot(@steps)}</div>

      <.link
        id={"#{@id}-action"}
        navigate={@action_href}
        class="mt-5 inline-flex min-h-target-min items-center text-body font-medium text-interactive-strong hover:text-interactive-strong-hover"
      >
        {@action_label || first_run_action_label(@state)}
      </.link>
    </section>
    """
  end

  defp first_run_action_label(:not_connected), do: "Open agent connection"
  defp first_run_action_label(:awaiting_evidence), do: "Check connection"

  @doc """
  The in-panel placeholder: a small dashed slot standing where a chart, a strip
  or a short list will be, with one plain sentence and at most one action.

  This is the only dashed frame in the console, and the visual spec draws it at
  exactly one size (`PostDeploy v3.dc.html` line 635): a 56px-tall slot inside
  an already-bordered panel. It is not a page hero. A screen whose entire body
  is empty uses `first_run_card/1`.

  It is also the documented exception to "a bordered container never contains
  another bordered container": the dashed slot marks absent content inside a
  panel, which is the shape the spec draws.

  ## Examples

      <.empty_state
        id="observe-releases-empty"
        title="No releases seen for this issue yet"
      />
  """
  attr :id, :string, default: nil
  attr :icon, :string, default: nil, doc: "optional 16px Lucide/heroicon before the sentence"
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, doc: "an optional single action"

  def empty_state(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "flex flex-col items-center justify-center gap-1 rounded-control border-[1.5px] border-dashed border-border-empty px-4 py-6 text-center",
        @class
      ]}
    >
      <p class="flex items-center gap-2 text-caption font-medium text-text-secondary">
        <.icon :if={@icon} name={@icon} class="size-4 shrink-0 text-text-tertiary" />
        <span>{@title}</span>
      </p>
      <p :if={@description} class="max-w-measure text-caption text-text-secondary">
        {@description}
      </p>
      <%!-- `w-full min-w-0`: the column centres its children, so without a
            width the action block grows to its widest child's intrinsic width
            and pushes the page past the viewport at 390px. --%>
      <div :if={@inner_block != []} class="mt-2 w-full min-w-0">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc """
  A permission-denied region: distinct from an error, with no retry (a retry
  cannot grant a role). Keeps the rest of the shell working.
  """
  attr :id, :string, default: nil
  attr :message, :string, default: "You don't have access to this."

  def permission_notice(assigns) do
    ~H"""
    <div
      id={@id}
      role="status"
      class="flex items-center gap-2 rounded-control border border-l-[3px] border-status-neutral-border border-l-status-neutral bg-surface-raised p-4 text-body text-text-secondary"
    >
      <.icon name="hero-lock-closed" class="size-5 shrink-0 text-status-neutral-ink" />
      <span>{@message}</span>
    </div>
    """
  end

  @doc """
  One row of the onboarding checklist. State is `:done`, `:current`, or
  `:todo` — derived from real persisted counts, never a stored flag
  (`docs/research/dashboard-ui-parity-plan.md` §6).
  """
  attr :state, :atom, required: true, values: [:done, :current, :todo]
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :id, :string, default: nil
  slot :inner_block, doc: "an optional action for the current step"

  def checklist_item(assigns) do
    ~H"""
    <li
      id={@id}
      data-state={@state}
      aria-current={@state == :current && "step"}
      class="flex items-start gap-3 py-3.5"
    >
      <span class={[
        "mt-0.5 flex size-6 shrink-0 items-center justify-center rounded-control border text-label font-semibold",
        checklist_marker_class(@state)
      ]}>
        <.icon :if={@state == :done} name="hero-check" class="size-3.5" />
        <.icon :if={@state == :current} name="hero-arrow-right" class="size-3.5" />
        <span :if={@state == :todo} class="block size-1.5 rounded-dot bg-current" />
      </span>
      <div class="min-w-0 flex-1">
        <%!-- The step's name outranks its explanation. It read at `text-label`
              over a `text-body` description, so the smaller line was the
              louder one and a finished step looked like a caption. --%>
        <p class={[
          "text-ui font-semibold",
          @state == :todo && "text-text-tertiary",
          @state != :todo && "text-text-primary"
        ]}>
          {@title}
        </p>
        <p :if={@description} class="mt-1 text-body text-text-secondary">{@description}</p>
        <div :if={@state == :current and @inner_block != []} class="mt-2">
          {render_slot(@inner_block)}
        </div>
      </div>
    </li>
    """
  end

  defp checklist_marker_class(:done),
    do: "border-status-live-border bg-status-live-bg text-status-live-ink"

  defp checklist_marker_class(:current),
    do: "border-interactive-primary bg-interactive-primary text-interactive-ink"

  defp checklist_marker_class(:todo),
    do: "border-border-default bg-surface-raised text-text-tertiary"

  @doc """
  A project selector, as a `phx-change="pick_project"` form. The host
  LiveView handles the event and navigates to the canonical project route.
  Renders nothing when there are no projects.
  """
  attr :projects, :list, required: true
  attr :project, :any, default: nil
  attr :id, :string, default: "project-select"
  attr :prompt, :string, default: "Select a project"

  def project_select(assigns) do
    ~H"""
    <form :if={@projects != []} id={@id} phx-change="pick_project" class="flex items-center gap-2">
      <label for={"#{@id}-input"} class="sr-only">Project</label>
      <div class="relative">
        <.icon
          name="hero-cube"
          class="pointer-events-none absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-text-tertiary"
        />
        <select
          id={"#{@id}-input"}
          name="project_id"
          class="h-control-md w-56 rounded-control border border-border-default bg-surface-raised pl-8 pr-3 text-body text-text-primary"
        >
          <option value="">{@prompt}</option>
          <option :for={p <- @projects} value={p.id} selected={@project && @project.id == p.id}>
            {p.name}
          </option>
        </select>
      </div>
    </form>
    """
  end

  @doc """
  An environment filter, as a `phx-change="pick_environment"` form. Renders
  only when a project is selected and at least one environment tag exists.
  Environment is a free-text tag, not a table (ARCHITECTURE.md §4).
  """
  attr :environments, :list, default: []
  attr :environment, :string, default: nil
  attr :id, :string, default: "environment-select"

  def environment_select(assigns) do
    ~H"""
    <form
      :if={@environments != []}
      id={@id}
      phx-change="pick_environment"
      class="flex items-center gap-2"
    >
      <label for={"#{@id}-input"} class="sr-only">Environment</label>
      <div class="relative">
        <.icon
          name="hero-swatch"
          class="pointer-events-none absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-text-tertiary"
        />
        <select
          id={"#{@id}-input"}
          name="environment"
          class="h-control-md w-44 rounded-control border border-border-default bg-surface-raised pl-8 pr-3 text-body text-text-primary"
        >
          <option value="" selected={is_nil(@environment)}>All environments</option>
          <option :for={env <- @environments} value={env} selected={@environment == env}>
            {env}
          </option>
        </select>
      </div>
    </form>
    """
  end

  @window_labels %{
    "24h" => "Last 24h",
    "7d" => "Last 7 days",
    "30d" => "Last 30 days",
    "90d" => "Last 90 days"
  }

  @doc "The human label for a window key, for a caller writing its own copy."
  def window_range_label(window), do: Map.get(@window_labels, window, window)

  @doc """
  The page header's time-range control: a segmented pill track (design source
  §12 "Measure, Traffic"), `pick_window` per segment.

  The design source offers exactly three ranges, and labels them in words
  rather than in axis shorthand: "Last 24h", "Last 7 days", "Last 30 days".
  A bare `7d` is a machine value; the control a person reaches for is a
  sentence fragment, so the mono token is wrong here.

  `dashboard_shell/1` renders this; a page passes `window` up rather than
  drawing its own copy, so the control sits in one place on every screen and
  a page with no time-scoped data renders no control at all.
  """
  attr :windows, :list, default: ~w(24h 7d 30d)
  attr :window, :string, required: true
  attr :id, :string, default: "window-select"

  def window_select(assigns) do
    ~H"""
    <div
      id={@id}
      class="inline-flex rounded-dot bg-surface-sunken p-0.5"
      role="group"
      aria-label="Time range"
    >
      <button
        :for={w <- @windows}
        type="button"
        phx-click="pick_window"
        phx-value-window={w}
        aria-pressed={to_string(@window == w)}
        class={[
          "h-control-sm cursor-pointer whitespace-nowrap rounded-dot px-3.5 text-label font-semibold transition-colors duration-productive",
          @window == w && "bg-surface-raised text-text-primary shadow-segment",
          @window != w && "text-text-tertiary hover:text-text-primary"
        ]}
      >
        {window_range_label(w)}
      </button>
    </div>
    """
  end

  @doc """
  A destructive-action confirmation control: a trigger button that expands
  into an inline panel with a consequence sentence, before the action runs
  (ARCHITECTURE.md §9: "typed confirmation for destructive actions").

  Two modes, chosen by domain consequence — not by verb:

    - `:typed` — irreversible or high-impact (delete org/project, revoke an
      API key, remove a member, reissue a heartbeat token, transfer
      ownership). The confirm button stays disabled until the typed text
      matches `match` exactly.
    - `:plain` — reversible or low-risk (pause/resume, rotate-with-grace,
      remove a domain that can be re-added). One extra click, no typed text.

  The host LiveView owns all state (`confirming`, `input_value`) and every
  handler this control's events name — this is markup only, so the real
  authorization gate is still the `handle_event` clause the host writes, per
  the Ash policy behind it.

  ## Examples

      <.destructive_confirm
        id={"revoke-\#{key.id}"}
        mode={:typed}
        match={key.name}
        confirming={@revoke_confirm_id == key.id}
        consequence="Every client using this key stops authenticating immediately. This cannot be undone."
        trigger_label="Revoke"
        confirm_label="Confirm revoke"
        trigger_event="confirm_revoke"
        cancel_event="cancel_revoke"
        confirm_event="revoke"
        input_event="revoke_input"
        input_value={@revoke_confirm_text}
        value_name="key_id"
        value={key.id}
      />

      <.destructive_confirm
        id={"remove-domain-\#{domain.id}"}
        mode={:plain}
        confirming={@domain_delete_confirm_id == domain.id}
        consequence="Measure stops accepting traffic from this domain until it is re-added."
        trigger_label="Remove"
        confirm_label="Confirm remove"
        trigger_event="confirm_delete_domain"
        cancel_event="cancel_delete_domain"
        confirm_event="delete_domain"
        value_name="id"
        value={domain.id}
      />
  """
  attr :id, :string, required: true
  attr :mode, :atom, default: :typed, values: [:typed, :plain]
  attr :confirming, :boolean, required: true
  attr :consequence, :string, required: true
  attr :match, :string, default: nil, doc: "required text for :typed mode"
  attr :trigger_label, :string, default: "Delete"
  attr :trigger_variant, :string, default: "secondary"
  attr :confirm_label, :string, default: "Confirm"
  attr :trigger_event, :string, required: true
  attr :cancel_event, :string, required: true
  attr :confirm_event, :string, required: true
  attr :input_event, :string, default: nil, doc: "phx-change name, :typed mode only"
  attr :input_value, :string, default: ""
  attr :value_name, :string, default: "id"
  attr :value, :any, required: true
  attr :focus_fallback_id, :string, default: nil
  attr :class, :any, default: nil

  attr :confirm_dialog, :string,
    default: nil,
    doc:
      "when set, the confirm button also carries a native browser data-confirm dialog " <>
        "(a second, OS-level confirmation on top of this panel, for the highest-consequence actions)"

  def destructive_confirm(assigns) do
    assigns =
      assigns
      |> assign(:value_attr, %{"phx-value-#{assigns.value_name}" => assigns.value})
      |> assign(
        :confirm_dialog_attr,
        if(assigns.confirm_dialog, do: %{"data-confirm" => assigns.confirm_dialog}, else: %{})
      )

    ~H"""
    <div
      id={"#{@id}-root"}
      class={@class}
      phx-hook=".DestructiveConfirmFocus"
      data-confirming={@confirming}
      data-focus-target={"#{@id}-#{if(@mode == :typed, do: "input", else: "submit")}"}
      data-trigger-id={"#{@id}-trigger"}
      data-focus-fallback-id={@focus_fallback_id}
    >
      <.button
        :if={not @confirming}
        type="button"
        variant={@trigger_variant}
        id={"#{@id}-trigger"}
        phx-click={@trigger_event}
        {@value_attr}
      >
        {@trigger_label}
      </.button>

      <div
        :if={@confirming}
        id={"#{@id}-confirm"}
        role="alert"
        aria-live="assertive"
        aria-labelledby={"#{@id}-consequence"}
        class="flex flex-wrap items-center gap-2 rounded-control border border-l-[3px] border-status-late-border border-l-status-late bg-surface-raised p-3"
      >
        <p id={"#{@id}-consequence"} class="w-full text-body text-text-secondary">
          {@consequence}
          <span :if={@mode == :typed}>
            Type <strong>{@match}</strong> to confirm.
          </span>
        </p>

        <form
          :if={@mode == :typed}
          id={"#{@id}-form"}
          phx-change={@input_event}
          phx-submit={@confirm_event}
          class="flex flex-wrap items-center gap-2"
        >
          <input type="hidden" name={@value_name} value={@value} />
          <%!-- `input/1` renders no label text unless it is given one, so
                without this the most consequential field in the console was an
                unnamed text box: a screen reader announced "edit text" with the
                "Type <match> to confirm" sentence sitting in a separate
                paragraph it never associates. The name repeats the match value
                on purpose — it is the whole instruction. --%>
          <.input
            type="text"
            name="confirm_text"
            id={"#{@id}-input"}
            value={@input_value}
            autocomplete="off"
            autofocus
            aria-label={"Type #{@match} to confirm"}
            class="h-control-md w-48 rounded-control border border-border-default bg-surface-raised px-2 text-body text-text-primary"
          />
          <.button
            type="submit"
            variant="destructive"
            id={"#{@id}-submit"}
            disabled={@input_value != @match}
            {@confirm_dialog_attr}
          >
            {@confirm_label}
          </.button>
          <.button
            type="button"
            variant="secondary"
            id={"#{@id}-cancel"}
            phx-click={@cancel_event}
            {@value_attr}
          >
            Cancel
          </.button>
        </form>

        <div :if={@mode == :plain} class="flex items-center gap-2">
          <.button
            type="button"
            variant="destructive"
            id={"#{@id}-submit"}
            autofocus={@mode == :plain}
            phx-click={@confirm_event}
            {@value_attr}
            {@confirm_dialog_attr}
          >
            {@confirm_label}
          </.button>
          <.button
            type="button"
            variant="secondary"
            id={"#{@id}-cancel"}
            phx-click={@cancel_event}
            {@value_attr}
          >
            Cancel
          </.button>
        </div>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".DestructiveConfirmFocus">
        export default {
          mounted() {
            this.confirming = this.el.dataset.confirming === "true"
            if (this.confirming) this.focusElement(this.el.dataset.focusTarget)
          },
          updated() {
            const confirming = this.el.dataset.confirming === "true"
            if (confirming === this.confirming) return

            this.confirming = confirming
            this.focusElement(confirming ? this.el.dataset.focusTarget : this.el.dataset.triggerId)
          },
          focusElement(id) {
            window.requestAnimationFrame(() => {
              const target = id && document.getElementById(id)
              const fallback = this.el.dataset.focusFallbackId &&
                document.getElementById(this.el.dataset.focusFallbackId)
              const destination = target || fallback ||
                document.querySelector("[data-destructive-focus-fallback]") ||
                document.getElementById("main-content")

              if (destination && typeof destination.focus === "function") {
                destination.focus({preventScroll: true})
              }
            })
          },
          destroyed() {
            this.focusElement(this.el.dataset.triggerId)
          }
        }
      </script>
    </div>
    """
  end

  @doc """
  A labelled definition row list, e.g. for a monitor config or an incident
  timeline. Replaces the legacy hand-rolled `dl`/`ConfigRow` markup.

  A row's value is a machine value by default and renders in the mono face:
  an address, a version, an interval, a token. Pass `face={:prose}` when the
  value is a sentence a person wrote ("Not assigned yet"), because prose is
  never mono. A row holding a `status_badge/1` needs neither, since the badge
  carries its own type.
  """
  slot :row, required: true do
    attr :label, :string, required: true

    attr :face, :atom,
      doc: ":machine (default) sets the value in mono, :prose sets it in the UI face"
  end

  def definition_list(assigns) do
    ~H"""
    <dl class="min-w-0 divide-y divide-border-default">
      <div :for={row <- @row} class="flex min-h-row min-w-0 items-start justify-between gap-3 py-3">
        <dt class="shrink-0 text-body text-text-secondary">{row.label}</dt>
        <dd class={[
          "min-w-0 break-words text-right font-semibold text-text-primary",
          if(row[:face] == :prose, do: "text-body", else: "text-data")
        ]}>
          {render_slot(row)}
        </dd>
      </div>
    </dl>
    """
  end

  @doc """
  A page-level header row: an optional leading block (e.g. breadcrumbs or a
  title) and a trailing, right-aligned block (e.g. a primary "New" action).
  Falls back to right-aligning the trailing block alone when there is no
  leading content, so a lone primary button still sits at the end of the row.
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil

  slot :leading
  slot :trailing

  def dashboard_header(assigns) do
    ~H"""
    <header
      id={@id}
      class={[
        "flex min-w-0 max-w-full flex-wrap items-center gap-4",
        header_justify_class(@leading),
        @class
      ]}
    >
      <div :if={@leading != []} class="min-w-0 max-w-full flex flex-wrap items-center gap-3">
        {render_slot(@leading)}
      </div>
      <div class="flex max-w-full flex-wrap gap-2">{render_slot(@trailing)}</div>
    </header>
    """
  end

  defp header_justify_class([]), do: "justify-end"
  defp header_justify_class(_leading), do: "justify-between"

  @doc """
  An accessible status dot: a colored circle paired with a text label, never
  color alone. The dot stays static so nonessential motion never competes with
  live status updates. Takes a plain tone, never a domain struct.

  ## Examples

      <.status_dot tone="success" label="Up" />
      <.status_dot tone="neutral" label="Paused" />
  """
  attr :tone, :string,
    default: "neutral",
    values: ~w(success warning error neutral live late paused)

  attr :label, :string, required: true
  attr :class, :any, default: nil

  attr :compact, :boolean,
    default: false,
    doc: "inline in a table cell or a dense row: no 44px reservation, the row carries the height"

  def status_dot(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1.5 rounded-control text-label text-text-secondary",
        not @compact && "min-h-target-min",
        @class
      ]}
      role="status"
      aria-label={@label}
      title={@label}
    >
      <span class={["size-2 shrink-0 rounded-dot", status_dot_tone_class(@tone)]} aria-hidden="true"></span>
      <.icon name={status_dot_icon(@tone)} class="size-4 shrink-0" />
      <span>{@label}</span>
    </span>
    """
  end

  defp status_dot_icon(tone) when tone in ["success", "live"], do: "hero-check-circle"
  defp status_dot_icon(tone) when tone in ["warning", "late"], do: "hero-exclamation-triangle"
  defp status_dot_icon("error"), do: "hero-x-circle"
  defp status_dot_icon("paused"), do: "hero-pause-circle"
  defp status_dot_icon(_neutral), do: "hero-information-circle"

  defp status_dot_tone_class("success"),
    do: "bg-status-live ring-2 ring-status-live-border"

  defp status_dot_tone_class("error"),
    do: "bg-status-error ring-2 ring-status-error-border"

  defp status_dot_tone_class("warning"), do: "bg-status-late"
  defp status_dot_tone_class("late"), do: "bg-status-late"
  defp status_dot_tone_class("live"), do: "bg-status-live"
  defp status_dot_tone_class("paused"), do: "bg-status-paused"
  defp status_dot_tone_class(_neutral), do: "bg-status-neutral"

  @doc """
  A collection summary band: a headline, an optional subtitle, a row of stat
  tiles, an optional trailing action, and optional full-width content below. Generic over the stats themselves — `stats` is a
  list of `%{id: string | nil, label: string, value: any, class: string |
  nil}`, never a domain struct.

  The stat grid's column count derives from `length(stats)`, so a band with
  three stats leaves no fourth column of dead space. Pass `columns` to
  override it — needed only when the `:extra` slot adds its own tiles.

  There is no eyebrow. The headline states the answer in the user's own words
  and carries its own weight; a small-caps label above it only ever repeated
  the section name.

  The `:actions` slot is where a page's primary action belongs. Putting it
  here rather than in a row of its own keeps a lone button from floating in
  dead space above the band.
  """
  attr :id, :string, required: true
  attr :headline, :string, required: true
  attr :subtitle, :string, default: nil
  attr :tabindex, :string, default: nil

  attr :stats, :list,
    required: true,
    doc: "%{id: string | nil, label: string, value: any, class: string | nil}"

  attr :columns, :integer,
    default: nil,
    doc: "override the derived stat-grid column count, e.g. when :extra adds tiles"

  slot :extra, doc: "additional dl content appended after the generated stat tiles"
  slot :actions, doc: "trailing controls, e.g. the page's primary action"
  slot :trend, doc: "optional full-width content below the stats, e.g. a distribution strip"

  def summary_card(assigns) do
    assigns = assign(assigns, :columns, assigns.columns || length(assigns.stats))

    ~H"""
    <section
      id={@id}
      tabindex={@tabindex}
      class="rounded-structural border border-border-default bg-surface-raised p-5"
      aria-labelledby={"#{@id}-title"}
    >
      <div class="flex flex-wrap items-start justify-between gap-x-6 gap-y-4">
        <div class="min-w-0">
          <h2 id={"#{@id}-title"} class="text-balance text-heading-02 text-text-primary">
            {@headline}
          </h2>
          <p :if={@subtitle} class="mt-1 text-body text-text-secondary">{@subtitle}</p>
        </div>
        <div class="flex flex-wrap items-start gap-x-6 gap-y-4">
          <dl class={[
            "grid gap-x-6 gap-y-2",
            stats_grid_class(@columns)
          ]}>
            <div :for={stat <- @stats} id={stat[:id]}>
              <dt class="text-label text-text-tertiary">{stat.label}</dt>
              <dd class={[
                "text-heading-02 font-semibold tabular-nums",
                stat[:class] || "text-text-primary"
              ]}>
                {stat.value}
              </dd>
            </div>
            {render_slot(@extra)}
          </dl>
          <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
            {render_slot(@actions)}
          </div>
        </div>
      </div>
      {render_slot(@trend)}
    </section>
    """
  end

  # Literal class strings so Tailwind's scanner sees every variant. Above two
  # stats the grid halves on mobile instead of cramming four numbers into a
  # 390px row.
  defp stats_grid_class(1), do: "grid-cols-1"
  defp stats_grid_class(2), do: "grid-cols-2"
  defp stats_grid_class(3), do: "grid-cols-2 sm:grid-cols-3"
  defp stats_grid_class(4), do: "grid-cols-2 sm:grid-cols-4"
  defp stats_grid_class(5), do: "grid-cols-2 sm:grid-cols-5"
  defp stats_grid_class(_many), do: "grid-cols-2 sm:grid-cols-4"

  @doc """
  The dashboard page scaffold. Every `/dashboard/` screen puts its sections
  inside exactly one of these, so geometry cannot drift between features.

  It settles five things and nothing else:

    * the outer gutter, which is the shell's `<main>` padding (16px, 24px from
      the `sm` breakpoint up), so a page never adds its own;
    * the vertical rhythm between sections, one 16px gap, matching the design
      source's 14 to 18px dashboard gaps;
    * the content width, `:full` by default because a console screen uses the
      page (design source §12). `:reading` is the one documented exception:
      a screen that is a sequence to follow rather than a dashboard to scan
      (design source §05 sets the MCP screen on a reading column);
    * the opening heading block: the `:title` slot draws the screen's one
      visible `<h1>` in the 19px page-summary role, left-aligned, above the
      intro. Every console screen then opens the same way. Pass
      `page_heading?={false}` to `dashboard_shell/1` alongside it, or the shell
      adds a second, `sr-only` `<h1>` and screen readers announce two;
    * the intro sentence, one plain-language line describing what the screen
      covers, always the same size and colour.

  Sections inside it are panels (`data_panel/1`, `section_card/1`,
  `summary_card/1`), never bare `space-y-*` wrappers with their own spacing,
  and never a loose paragraph or copy row on the page background.

  ## Examples

      <.console_page id="team-page">
        <:title>Team</:title>
        <:intro>Everyone who can open this organization.</:intro>
        <.data_panel id="members" title="Members">...</.data_panel>
      </.console_page>
  """
  attr :id, :string, required: true

  attr :width, :atom,
    default: :full,
    values: [:full, :reading],
    doc: ":reading caps a follow-this-sequence screen at the prose column"

  attr :class, :any, default: nil
  slot :title, doc: "the screen's one visible h1; the shell must then skip its own"
  slot :intro, doc: "one plain-language sentence naming what this screen covers"
  slot :inner_block, required: true

  def console_page(assigns) do
    ~H"""
    <div
      id={@id}
      class={
        [
          # 24px between the page's major sections. A group of sibling cards
          # inside one section closes to 16px, and the contrast between the two
          # is what makes the page read as groups rather than one flat stack.
          "flex w-full min-w-0 flex-col gap-6",
          @width == :reading && "max-w-content",
          @class
        ]
      }
    >
      <div :if={@title != [] or @intro != []} class="flex flex-col gap-1.5">
        <%!-- The page's one h1, at the console content scale: 28px on a
              desktop canvas, 22px on a phone (theme-console.css). --%>
        <h1 :if={@title != []} id={"#{@id}-heading"} class="text-heading-01 text-text-primary">
          {render_slot(@title)}
        </h1>
        <p :if={@intro != []} class="max-w-prose text-body-long text-text-secondary">
          {render_slot(@intro)}
        </p>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  A flush bordered data frame: a header row (title, optional description,
  optional actions) above an unpadded body.

  Use this, never `section_card/1`, for a region whose body is a table or a
  list of rows. `section_card/1`'s own gutter forces a caller to nest a second
  bordered box inside it to hold the rows, and a bordered container inside a
  bordered container is the console's one hard layout ban. Here the body is
  edge-to-edge, so a table's `divide-y` becomes the frame's internal rules
  and the frame keeps exactly one border.

  `padded` adds the `section_card` gutter back for a body that is genuinely
  a block of content rather than rows (a form, a paragraph, an empty state).

  ## Examples

      <.data_panel id="members" title="Members" description="Everyone with access.">
        <:actions><.button>Invite</.button></:actions>
        <table>...</table>
      </.data_panel>
  """
  attr :id, :string, required: true
  attr :title, :string, default: nil
  attr :description, :string, default: nil
  attr :padded, :boolean, default: false, doc: "restore the card gutter for non-row content"
  attr :class, :any, default: nil

  slot :inner_block, required: true
  slot :actions

  slot :footer,
    doc: "the explanatory sentence strip under the body (DESIGN.md, card anatomy)"

  def data_panel(assigns) do
    ~H"""
    <section
      id={@id}
      class={[
        "w-full min-w-0 max-w-full overflow-hidden rounded-structural border border-border-default bg-surface-raised",
        @class
      ]}
      aria-labelledby={@title && "#{@id}-title"}
    >
      <div
        :if={@title || @actions != []}
        class="flex flex-wrap items-start justify-between gap-x-4 gap-y-3 border-b border-border-default px-5 py-3.5"
      >
        <div :if={@title} class="min-w-0">
          <%!-- `text-heading-03` is the panel-title role: one step above the
                rows beneath it, one step below a summary band's headline. --%>
          <h2 id={"#{@id}-title"} class="text-heading-03 text-text-primary">{@title}</h2>
          <p :if={@description} class="mt-1 text-body text-text-secondary">{@description}</p>
        </div>
        <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
          {render_slot(@actions)}
        </div>
      </div>
      <div class={["min-w-0 max-w-full", @padded && "p-5"]}>{render_slot(@inner_block)}</div>
      <%!-- A sentence that explains the panel belongs to the panel. Nothing in
            the console is a loose paragraph on the page background. --%>
      <div
        :if={@footer != []}
        class="border-t border-border-subtle px-5 py-3.5 text-caption text-text-secondary"
      >
        {render_slot(@footer)}
      </div>
    </section>
    """
  end
end
