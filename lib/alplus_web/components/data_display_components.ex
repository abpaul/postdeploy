defmodule AlplusWeb.DataDisplayComponents do
  @moduledoc """
  Shared accessible grammar for compact and full data displays.

  Call `data_display/1` with a `kind` from `:bucket_bar`, `:ticks`, `:step`,
  `:wave`, `:line`, `:stacked`, `:histogram`, `:ranked_bar`,
  `:proportional_meter`, or `:day_grid`.

  The caller owns domain shaping. Each item supplies its label, value, state,
  tooltip, and optional `height` or `width`. Line and wave callers supply an
  SVG path. The component never interpolates samples or calculates a domain.

  `variant: :compact` renders a summary and a touch and keyboard accessible
  visual. `variant: :full` adds explicit range and unit labels plus a table
  alternative. Full displays with data require `table_columns` and a
  `:table_cells` list on every canonical data record. The component derives
  table rows from those same records and rejects caller-supplied `table_rows`,
  so a same-width but different table can never replace the visual values.
  All states use the same interface: `:loading`, `:empty`, `:partial`,
  `:error`, `:disabled`, `:permission`, `:unavailable`, and `:anomaly`.

  `plot_height` picks the depth of the plot slot: `:standard` for a panel
  among panels, `:tall` for the one primary chart on a screen. Every state,
  including `:empty`, holds the height its `:ready` state will take.

  A bucket nobody measured is drawn as an absence, never as a value, and
  never as scenery: no gray slab, no decorative squiggle. The caller states
  the shortfall in words above the plot and the table below lists every
  bucket.
  """

  use AlplusWeb, :html

  @kinds [
    :bucket_bar,
    :ticks,
    :step,
    :wave,
    :line,
    :stacked,
    :histogram,
    :ranked_bar,
    :proportional_meter,
    :day_grid
  ]

  @compact_tick_cap 14
  @full_tick_cap 36
  # A 44px-tall target still needs ~27px of width to be hittable on a 390px
  # viewport once the chart's own padding is taken off. Twelve samples is the
  # most a line can offer at that width without the targets touching.
  @line_sample_cap 12
  # The plot sits inside the card's own padding, so an end target may reach
  # this far past the plot edge without leaving the card.
  @edge_outset 12

  attr :id, :string, required: true
  attr :title, :string, required: true

  # A nested display sits inside a container that has already named the
  # metric and the period ("PAGE VIEWS / LAST 24 HOURS" above the number it
  # belongs to). Repeating that string as a visible heading makes two
  # independent authors of one sentence. `:assistive` keeps the `h3` as the
  # section's accessible name and takes it out of the reading path.
  attr :heading, :atom, default: :visible, values: [:visible, :assistive]
  attr :kind, :atom, required: true
  attr :variant, :atom, default: :compact

  attr :state, :atom,
    default: :ready,
    values: [
      :ready,
      :loading,
      :empty,
      :partial,
      :error,
      :disabled,
      :permission,
      :unavailable,
      :anomaly
    ]

  attr :data, :list, default: []
  attr :preserve_points, :boolean, default: false
  attr :unit, :string, default: nil
  attr :range, :map, default: nil
  attr :thresholds, :list, default: []
  attr :annotations, :list, default: []
  attr :legend, :list, default: []
  attr :summary, :string, default: nil
  attr :description, :string, default: nil
  # Kept as a migration-time guard for callers that still pass the old
  # arbitrary-row interface. Rows are never rendered from this value.
  attr :table_rows, :list, default: nil
  attr :table_columns, :list, default: []
  attr :svg_path, :string, default: nil
  attr :svg_area, :string, default: nil
  attr :overlays, :list, default: []
  # How deep the plot slot is. `:standard` is the 120/160px height every
  # console panel draws at; `:tall` is the 160/248px slot a primary chart
  # among panels earns; `:hero` is the 224/420px slot for a screen that is
  # one chart and nothing else. Three heights are a hierarchy; more is a
  # lottery.
  #
  # There is no `regions` attribute. A stretch nobody measured is stated in
  # words above the plot and left blank in it; the gray slab this component
  # used to draw sat exactly where the chart belongs and read as a chart that
  # had failed rather than as an absence of data.
  attr :plot_height, :atom, default: :standard, values: [:standard, :tall, :hero]
  attr :line_class, :string, default: "stroke-chart-p99 fill-chart-p99"
  attr :line_width, :string, default: "1.5"
  # Where the time axis reads. `:top` is the range row above the plot every
  # panel draws; `:bottom` keeps that row for assistive technology only and
  # draws the caller's `x_labels` (`%{position: 0..100, label: "Jun 10"}`)
  # as tick labels under the plot, which is where a hero chart's dates belong.
  attr :axis, :atom, default: :top, values: [:top, :bottom]
  attr :x_labels, :list, default: []
  # Stretches of the plot nobody measured (`%{left: 0..100, width: 0..100}`),
  # drawn as hatched ground under the line so an untracked span reads as
  # untracked rather than as zero or as a chart that stopped.
  attr :shades, :list, default: []
  # The sentence inside the `:empty` frame. A hero chart states what is
  # absent in the caller's own words ("No pageviews in the last 24 hours.")
  # rather than the generic line every small panel shares.
  attr :empty_label, :string, default: "No data in this range yet."
  # How the exact table alternative is offered. `:disclosure` is the "View
  # data table" fold every panel draws; `:assistive` keeps the same table for
  # screen readers only, for a hero chart whose points already carry their
  # values and whose one visible control would be chrome under the plot.
  attr :table, :atom, default: :disclosure, values: [:disclosure, :assistive]
  attr :retry_event, :string, default: nil
  attr :class, :string, default: nil

  @doc "Renders one compact or full display from the shared data grammar."
  def data_display(assigns) do
    unless assigns.kind in @kinds do
      raise ArgumentError, "unsupported data display kind: #{inspect(assigns.kind)}"
    end

    assigns = assign_new(assigns, :description, fn -> assigns.title end)
    validate_full_table!(assigns)

    {table_rows, table_columns} = resolve_table(assigns)

    assigns =
      assigns
      |> assign(
        :visual_data,
        if(assigns.preserve_points,
          do: assigns.data,
          else: visual_series(assigns.kind, assigns.variant, assigns.data)
        )
      )
      |> assign(:resolved_table_rows, table_rows)
      |> assign(:resolved_table_columns, table_columns)

    ~H"""
    <section
      id={@id}
      class={["data-display min-w-0", @class]}
      data-display-kind={@kind}
      data-display-variant={@variant}
      data-display-state={@state}
      data-touch-tooltip="true"
      data-keyboard-tooltip="true"
      phx-hook=".DisplayPoints"
      aria-labelledby={"#{@id}-title"}
    >
      <div class="flex flex-wrap items-start justify-between gap-2">
        <div class="min-w-0">
          <h3
            id={"#{@id}-title"}
            class={
              if(@heading == :assistive,
                do: "sr-only",
                else: "text-label font-semibold text-text-primary"
              )
            }
          >
            {@title}
          </h3>
          <%!-- In the `:error` state the red slot below already prints
                `@summary` as the specific reason the producer wrote. Printing
                it here too put the same sentence on the card twice. --%>
          <p
            :if={@summary && @state != :error}
            id={"#{@id}-summary"}
            class="text-data text-text-secondary"
          >
            {@summary}
          </p>
        </div>
        <span
          :if={@unit}
          class="sr-only"
          data-display-unit={@unit}
        >
          Unit: {@unit}
        </span>
      </div>

      <%!-- Three mono cells cannot share a 326px column: the endpoints wrap
            mid-word and the hint between them shatters. Below `sm` the hint
            takes a line of its own under the endpoints, which keeps every
            label whole and never truncates a caption. --%>
      <div
        :if={@range && !hide_axis?(@kind, @variant) && @axis == :top}
        id={"#{@id}-range"}
        class="mt-2 flex flex-wrap justify-between gap-x-2 font-mono text-[10.5px] text-text-tertiary"
        data-display-range="true"
      >
        <span class="whitespace-nowrap">
          <span class="sr-only">Range start: {Map.get(@range, :start)}</span>
          <span aria-hidden="true">{Map.get(@range, :start)}</span>
        </span>
        <span class="order-last basis-full sm:order-none sm:basis-auto">{axis_hint(
          @kind,
          @unit,
          @range
        )}</span>
        <span class="whitespace-nowrap">
          <span class="sr-only">Range end: {Map.get(@range, :end)}</span>
          <span aria-hidden="true">{Map.get(@range, :end)}</span>
        </span>
      </div>

      <div
        :if={@range && (hide_axis?(@kind, @variant) || @axis == :bottom)}
        id={"#{@id}-range"}
        class="sr-only"
        data-display-range="true"
      >
        <span>Range start: {Map.get(@range, :start)}</span>
        <span>Range end: {Map.get(@range, :end)}</span>
      </div>

      <div
        :if={@state == :loading}
        id={"#{@id}-loading"}
        class="mt-3 rounded-control bg-surface-sunken p-3"
        role="status"
        aria-live="polite"
      >
        <div class="flex items-end gap-0.5" aria-hidden="true">
          <span
            :for={height <- ["h-3", "h-5", "h-4", "h-6", "h-3", "h-5"]}
            class={["w-3 rounded-tick bg-border-default", height]}
          ></span>
        </div>
        <p class="mt-2 text-data text-text-secondary">Loading data</p>
      </div>

      <%!-- An empty plot keeps its plot. The header, the range row above and
            the baseline below stay exactly where they will be once data
            arrives, so the reader learns the shape of the answer before there
            is one and the card does not resize under them. Only a `:full`
            display that also states its range holds a real plot height: a
            range means there is an axis above the plot to hold up. A compact
            display, or a full one with no axis, keeps the small slot the
            visual spec draws. --%>
      <div
        :if={@state == :empty}
        id={"#{@id}-empty"}
        class={[
          "mt-3 flex flex-col rounded-control border-[1.5px] border-dashed border-border-empty px-4 pb-3 pt-4",
          if(@plot_height == :hero, do: "justify-center", else: "justify-end"),
          if(@variant == :full and @range,
            do: empty_slot_class(@plot_height),
            else: "min-h-14"
          )
        ]}
        role="status"
      >
        <p class="text-center text-label font-medium text-text-secondary">
          {@empty_label}
        </p>
        <span
          :if={@variant == :full and not is_nil(@range) and @plot_height != :hero}
          aria-hidden="true"
          class="mt-4 block h-px w-full bg-border-default"
        ></span>
      </div>

      <div
        :if={@state == :error}
        id={"#{@id}-error"}
        class="mt-3 flex min-h-14 flex-wrap items-center justify-center gap-2 rounded-control bg-status-error-bg px-3 py-2 text-label font-medium text-status-error-ink"
        role="alert"
      >
        <%!-- An error names what went wrong. The producer already writes a
             specific reason ("The monitor check interval is unavailable."),
             so showing the generic sentence instead threw away the only part
             a reader could act on. --%>
        <span :if={@summary}>{@summary}</span>
        <span :if={is_nil(@summary)}>We couldn't load this chart. Try again.</span>
        <button
          :if={@retry_event}
          type="button"
          phx-click={@retry_event}
          class="h-control-md rounded-control-sm border border-status-error-border px-3 text-label font-medium text-status-error-ink hover:bg-surface-raised focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
        >Retry</button>
      </div>

      <div
        :if={@state in [:disabled, :permission, :unavailable]}
        id={"#{@id}-#{@state}"}
        class={[
          "mt-3 flex items-start gap-2 rounded-control border p-3 text-body",
          state_notice_class(@state)
        ]}
        role="status"
      >
        <.icon name={state_notice_icon(@state)} class="mt-0.5 size-5 shrink-0" />
        <span>{state_message(@state)}</span>
      </div>

      <div :if={@state in [:ready, :partial, :anomaly]} class="mt-3">
        <div class={[
          "relative",
          (@thresholds != [] or @annotations != []) && "pt-5"
        ]}>
          <.visual
            id={@id}
            title={@title}
            kind={@kind}
            variant={@variant}
            data={@visual_data}
            unit={@unit}
            svg_path={@svg_path}
            svg_area={@svg_area}
            overlays={@overlays}
            plot_height={@plot_height}
            line_class={@line_class}
            line_width={@line_width}
            x_labels={@x_labels}
            shades={@shades}
          />

          <div
            :if={@kind in [:bucket_bar, :histogram, :step, :wave, :line]}
            class="pointer-events-none absolute inset-0"
            aria-hidden="true"
          >
            <div
              :for={threshold <- @thresholds}
              :if={is_number(Map.get(threshold, :position)) and Map.get(threshold, :axis, :y) != :x}
              class="absolute inset-x-0 border-t border-dashed border-status-late"
              style={"bottom: #{Map.get(threshold, :position)}%"}
            >
              <span class="absolute -top-4 right-0 whitespace-nowrap font-mono text-[10px] text-status-late-ink">
                {Map.get(threshold, :label) || "Threshold"}
              </span>
            </div>
            <div
              :for={threshold <- @thresholds}
              :if={is_number(Map.get(threshold, :position)) and Map.get(threshold, :axis) == :x}
              class="absolute inset-y-0 border-l border-dashed border-status-late"
              style={"left: #{Map.get(threshold, :position)}%"}
            >
              <span class="absolute -top-2 left-0 translate-x-1 whitespace-nowrap font-mono text-[10px] text-status-late-ink">
                {Map.get(threshold, :label) || "Threshold"}
              </span>
            </div>
            <%!-- The guide line fades; its label must not. `opacity` applies to
                  the whole subtree, so a label nested inside the faded line
                  rendered at 20 percent, about 1.3:1, and no reader could see
                  which deploy the marker named. The line now carries the fade
                  on its own element, and the label takes the ink pill the
                  design source draws (DESIGN.md, "Charts in the dashboard"). --%>
            <div
              :for={annotation <- @annotations}
              :if={is_number(Map.get(annotation, :position))}
              class="absolute inset-y-0 w-px"
              style={"left: #{Map.get(annotation, :position)}%"}
            >
              <span
                aria-hidden="true"
                class="absolute inset-0 block bg-interactive-ink opacity-20"
              ></span>
              <span class="absolute -top-2 left-0 translate-x-1 whitespace-nowrap rounded-control-sm bg-surface-inverse px-1.5 py-0.5 font-mono text-[10px] text-text-inverse">
                ▲ {Map.get(annotation, :label) || "Deploy"}
              </span>
            </div>
          </div>
        </div>

        <div :if={@thresholds != []} class="mt-2 grid gap-1" aria-label="Thresholds">
          <div
            :for={threshold <- @thresholds}
            class="flex items-center justify-between gap-2 text-data text-text-secondary"
            data-display-threshold={Map.get(threshold, :label) || Map.get(threshold, :value)}
          >
            <span>{Map.get(threshold, :label) || "Threshold"}</span>
            <span :if={Map.get(threshold, :value)}>{Map.get(threshold, :value)} {@unit}</span>
          </div>
        </div>

        <div :if={@annotations != []} class="mt-2 flex flex-wrap gap-2" aria-label="Annotations">
          <span
            :for={annotation <- @annotations}
            class="rounded-control-sm border border-border-default bg-surface-sunken px-2 py-1 text-data text-text-secondary"
            data-display-annotation={Map.get(annotation, :label)}
          >
            {Map.get(annotation, :label) || "Annotation"}
          </span>
        </div>

        <div :if={@legend != []} class="mt-3 flex flex-wrap gap-x-4 gap-y-1" aria-label="Legend">
          <span
            :for={entry <- @legend}
            class="inline-flex items-center gap-1.5 text-data text-text-secondary"
          >
            <span
              class={["h-2.5 w-2.5 rounded-dot", tone_class(Map.get(entry, :tone))]}
              aria-hidden="true"
            ></span>
            <span>{Map.get(entry, :label)}</span>
            <span :if={Map.get(entry, :count) != nil}>({Map.get(entry, :count)})</span>
          </span>
        </div>

        <%!-- The generic verdict, in dot and word. On a `:compact` strip the
              caller's summary already names the same condition with real
              counts ("Partial coverage, 1 of 97 monitor intervals missing"),
              and printing both put the same fact on the row twice. The
              specific sentence wins; a full display keeps both because its
              summary is a short axis caption. --%>
        <p
          :if={@state == :anomaly and (@variant == :full or is_nil(@summary))}
          id={"#{@id}-state"}
          class={["mt-2 flex items-center gap-1.5 text-data font-medium", state_text_class(@state)]}
          role="status"
        >
          <span class={["h-2 w-2 rounded-dot", state_dot_class(@state)]} aria-hidden="true"></span>
          {state_message(@state)}
        </p>
      </div>

      <%!-- The table alternative belongs to `:full`, as this module's contract
            says. A `:compact` strip is an inline glance beside a number: its
            textual equivalent is the summary sentence plus the per-point
            `aria-label`, and unfolding a seven-column table under every row of
            an index list buries the list it was meant to explain. --%>
      <%!-- One Tab stop enters the plot; the arrow keys walk its points in
            time order, Enter keeps one open here, Escape lets it go. The
            kept point is announced and stays visible until the reader moves
            on, so a value can be read, compared and copied without hovering. --%>
      <p
        :if={@state in [:ready, :partial, :anomaly] and @visual_data != []}
        id={"#{@id}-keys"}
        class="sr-only"
      >
        {length(@visual_data)} points. Use the left and right arrow keys to move between them, Enter to keep one open, Escape to close it.
      </p>
      <p
        :if={@state in [:ready, :partial, :anomaly] and @visual_data != []}
        id={"#{@id}-selected"}
        data-display-selected
        role="status"
        aria-live="polite"
        class="mt-2 hidden rounded-control-sm bg-surface-sunken px-3 py-2 text-caption text-text-primary"
      >
      </p>

      <.data_table
        :if={
          @variant == :full and @state in [:ready, :partial, :anomaly] and
            @resolved_table_rows != []
        }
        id={"#{@id}-table"}
        rows={@resolved_table_rows}
        columns={@resolved_table_columns}
        assistive={@table == :assistive}
      />

      <p :if={@description} class="sr-only">{@description}</p>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".DisplayPoints">
        export default {
          mounted() {
            this.setup()
            this.onKey = (event) => this.keydown(event)
            this.onClick = (event) => {
              const point = event.target.closest("[data-display-point]")
              if (point && this.el.contains(point)) this.select(point, false)
            }
            this.el.addEventListener("keydown", this.onKey)
            this.el.addEventListener("click", this.onClick)
          },
          updated() {
            this.setup()
          },
          destroyed() {
            this.el.removeEventListener("keydown", this.onKey)
            this.el.removeEventListener("click", this.onClick)
          },
          points() {
            return Array.from(this.el.querySelectorAll("[data-display-point]"))
          },
          setup() {
            const points = this.points()
            const current = points.find(p => p.getAttribute("tabindex") === "0") || points[0]
            points.forEach(p => {
              p.setAttribute("tabindex", p === current ? "0" : "-1")
              if (!p.hasAttribute("aria-pressed")) p.setAttribute("aria-pressed", "false")
            })
            const keys = this.el.querySelector("[id$='-keys']")
            const group = this.el.querySelector("[data-display-visual]")
            if (keys && group && !group.getAttribute("aria-describedby")) group.setAttribute("aria-describedby", keys.id)
          },
          keydown(event) {
            const point = event.target.closest("[data-display-point]")
            if (!point) return
            const points = this.points()
            const index = points.indexOf(point)
            let next = null
            if (event.key === "ArrowRight" || event.key === "ArrowDown") next = points[Math.min(index + 1, points.length - 1)]
            if (event.key === "ArrowLeft" || event.key === "ArrowUp") next = points[Math.max(index - 1, 0)]
            if (event.key === "Home") next = points[0]
            if (event.key === "End") next = points[points.length - 1]
            if (next) {
              event.preventDefault()
              points.forEach(p => p.setAttribute("tabindex", p === next ? "0" : "-1"))
              next.focus()
              return
            }
            if (event.key === "Enter" || event.key === " ") {
              event.preventDefault()
              this.select(point, true)
            }
            if (event.key === "Escape" && this.el.querySelector("[aria-pressed='true']")) {
              event.preventDefault()
              event.stopPropagation()
              this.clear()
            }
          },
          select(point, toggle) {
            const pressed = point.getAttribute("aria-pressed") === "true"
            this.points().forEach(p => p.setAttribute("aria-pressed", "false"))
            const panel = this.el.querySelector("[data-display-selected]")
            if (pressed && toggle) {
              this.clear()
              return
            }
            point.setAttribute("aria-pressed", "true")
            if (panel) {
              panel.textContent = point.getAttribute("aria-label") || point.textContent.trim()
              panel.classList.remove("hidden")
            }
          },
          clear() {
            this.points().forEach(p => p.setAttribute("aria-pressed", "false"))
            const panel = this.el.querySelector("[data-display-selected]")
            if (panel) {
              panel.textContent = ""
              panel.classList.add("hidden")
            }
          }
        }
      </script>
    </section>
    """
  end

  defp visual(assigns) do
    ~H"""
    <div
      id={"#{@id}-visual"}
      class={visual_container_class(@kind)}
      role="group"
      aria-label={@title}
      data-display-visual="true"
    >
      <div
        :if={@kind == :ticks}
        class={[
          "flex items-stretch gap-0.5 overflow-visible",
          if(@variant == :compact, do: "h-6", else: "h-8")
        ]}
      >
        <div
          :for={{item, index} <- Enum.with_index(@data)}
          class="group relative min-w-0 flex-1 hover:z-10 focus-within:z-20"
        >
          <%!-- A mixed bucket (a fleet where one monitor is down while another
                is healthy) stacks its parts instead of painting the whole
                tick in its worst colour, so the strip shows the ratio the
                text states. A bucket still in progress carries a hatch. --%>
          <span
            aria-hidden="true"
            class={[
              "absolute inset-0 flex flex-col-reverse overflow-hidden rounded-tick",
              item_segments(item) == [] && tone_class(item_tone(item)),
              item_in_progress?(item) && "chart-in-progress"
            ]}
          >
            <span
              :for={segment <- item_segments(item)}
              class={["block w-full", tone_class(Map.get(segment, :tone))]}
              style={"height: #{segment_height(segment)}%"}
            ></span>
          </span>
          <button
            type="button"
            class="absolute inset-x-0 top-1/2 min-h-target-min -translate-y-1/2 cursor-pointer rounded-tick border border-transparent bg-transparent focus-visible:border-focus focus-visible:outline-2 focus-visible:outline-offset-1 aria-pressed:border-focus"
            data-display-point="true"
            data-touch-tooltip="true"
            tabindex={point_tabindex(index)}
            aria-label={item_aria(item, @unit)}
          >
            <span class="sr-only">{item_aria(item, @unit)}</span>
          </button>
          <span
            role="tooltip"
            aria-hidden="true"
            class={[
              "pointer-events-none absolute bottom-full z-30 hidden w-max max-w-[min(18rem,calc(100vw-2rem))] whitespace-normal break-words rounded-control-sm border border-border-default bg-surface-raised px-2 py-1 text-tooltip text-text-primary shadow-overlay group-focus-within:block group-hover:block",
              tooltip_position_class(index, length(@data))
            ]}
          >
            {item_tooltip(item, @unit)}
          </span>
        </div>
      </div>

      <%!-- A `:full` bucket chart is the primary answer on its screen, so it
            gets a plot deep enough to read a shape in. `:compact` is the
            inline strip beside a number and keeps the 72px it was drawn at. --%>
      <div
        :if={@kind == :bucket_bar}
        class={[
          "flex items-end gap-0.5 overflow-visible",
          if(@variant == :full, do: plot_class(@plot_height), else: "h-[72px]")
        ]}
      >
        <div
          :for={{item, index} <- Enum.with_index(@data)}
          class="group relative h-full min-w-0 flex-1 hover:z-10 focus-within:z-20"
          data-display-measured={to_string(item_measured?(item))}
        >
          <%!-- Three facts, three marks. A measured reading is a column; a
                measured zero is a 2px mark on the floor, because a zero
                somebody counted is a reading; a bucket nobody measured has no
                column at all and shows only a dashed floor tick, so the slot
                is visibly present and visibly unanswered. Drawing the stub
                for the unmeasured case and nothing for the measured zero -
                which is what a single `|| "height: 2px"` did - inverted the
                two.

                The bar is capped at 64px and centred in its cell. A week of
                daily buckets across a 1400px panel otherwise draws seven
                220px slabs, which reads as a block of colour rather than as a
                chart. Above about twenty buckets the cell is already narrower
                than the cap, so the cap does nothing and the strip stays
                continuous. --%>
          <span
            :if={not item_measured?(item)}
            aria-hidden="true"
            class="absolute inset-x-0 bottom-0 border-t border-dashed border-border-empty"
          ></span>
          <span
            :if={item_measured?(item)}
            aria-hidden="true"
            class={[
              "absolute bottom-0 left-1/2 w-full max-w-16 -translate-x-1/2 rounded-t-tick",
              tone_class(item_tone(item)),
              item_in_progress?(item) && "chart-in-progress"
            ]}
            style={bar_style(item)}
          ></span>
          <%!-- The reference cap is the comparison period's own measurement in
                this same bucket, at its own height. It is drawn only where
                that bucket was measured: a flat track across the plot would
                be an invented prior, not a comparison. --%>
          <span
            :if={reference_style(item)}
            aria-hidden="true"
            class="absolute left-1/2 h-0.5 w-full max-w-16 -translate-x-1/2 bg-chart-previous"
            style={reference_style(item)}
            data-display-reference="true"
          ></span>
          <button
            type="button"
            class="absolute inset-x-0 bottom-0 min-h-target-min cursor-pointer rounded-t-tick border border-transparent bg-transparent focus-visible:border-focus focus-visible:outline-2 focus-visible:outline-offset-1 aria-pressed:border-focus"
            data-display-point="true"
            data-touch-tooltip="true"
            tabindex={point_tabindex(index)}
            aria-label={item_aria(item, @unit)}
          >
            <span class="sr-only">{item_aria(item, @unit)}</span>
          </button>
          <span
            role="tooltip"
            aria-hidden="true"
            class={[
              "pointer-events-none absolute bottom-full z-30 hidden w-max max-w-[min(18rem,calc(100vw-2rem))] whitespace-normal break-words rounded-control-sm border border-border-default bg-surface-raised px-2 py-1 text-tooltip text-text-primary shadow-overlay group-focus-within:block group-hover:block",
              tooltip_position_class(index, length(@data))
            ]}
          >
            {item_tooltip(item, @unit)}
          </span>
        </div>
      </div>

      <div
        :if={@kind in [:step, :wave, :line]}
        class={["relative overflow-visible", min_plot_class(@plot_height)]}
      >
        <%!-- A stretch nobody measured is left blank. The plot keeps its floor
              rule and its axis, the coverage sentence above it says in words
              how much of the range was measured, and the table below lists
              every bucket. Nothing is drawn where nothing was recorded. --%>
        <%!-- `preserveAspectRatio="none"` makes the 0-100 viewBox x axis the
              container's own width, so a sample's normalized x is the same
              percentage in the SVG and in the hit layer below. Without it the
              plot letterboxes to its 2.5:1 ratio and every target points at
              empty space. --%>
        <div
          :for={shade <- @shades}
          data-display-shade="true"
          class="absolute top-2 z-20 h-px border-t border-dashed border-status-neutral"
          style={"left: #{Map.get(shade, :left)}%; width: #{Map.get(shade, :width)}%"}
        >
          <span
            :if={Map.get(shade, :label) && Map.get(shade, :width) >= 12}
            class="absolute left-0 top-1 whitespace-nowrap bg-surface-raised pr-1 font-mono text-[10.5px] text-text-tertiary"
          >
            {Map.get(shade, :label)}
          </span>
          <span
            :if={Map.get(shade, :end_label) && Map.get(shade, :width) >= 18}
            class="absolute right-0 top-1 whitespace-nowrap bg-surface-raised pl-1 font-mono text-[10.5px] text-text-tertiary"
          >
            {Map.get(shade, :end_label)}
          </span>
        </div>
        <svg
          viewBox="0 0 100 40"
          preserveAspectRatio="none"
          class={["relative z-10 w-full overflow-visible", plot_class(@plot_height)]}
          aria-hidden="true"
          focusable="false"
        >
          <path :if={@svg_area} d={@svg_area} class={["opacity-30", fill_only(@line_class)]} />
          <path
            :if={@svg_path}
            d={@svg_path}
            class={["fill-none", stroke_only(@line_class)]}
            stroke-width={@line_width}
            stroke-linejoin="round"
            stroke-linecap="round"
            vector-effect="non-scaling-stroke"
          />
          <%!-- An overlay is any second stroke over the same box: a period
                behind this one, a link across a gap, a floor rule, or - with a
                round cap on a zero-length subpath - one dot per reading. --%>
          <path
            :for={overlay <- @overlays}
            d={Map.get(overlay, :path)}
            class={["fill-none", stroke_only(Map.get(overlay, :class, @line_class))]}
            stroke-width={Map.get(overlay, :width, "1.3")}
            stroke-dasharray={Map.get(overlay, :dash)}
            stroke-linecap={Map.get(overlay, :linecap)}
            vector-effect="non-scaling-stroke"
          />
        </svg>
        <span
          :for={overlay <- @overlays}
          :if={Map.get(overlay, :label)}
          class="pointer-events-none absolute right-0 -translate-y-1/2 bg-surface-raised pl-1.5 font-mono text-[10.5px] text-text-tertiary"
          style={"top: #{Map.get(overlay, :label_y, 0)}"}
        >
          {Map.get(overlay, :label)}
        </span>
        <%!-- Each target keeps the x of the sample it names and claims the
              space up to the midpoint between it and its neighbours, so a hit
              always resolves to the nearest plotted reading. Equal-width
              re-layout would have moved the targets off their own points, and
              the 44px-wide centred targets they replaced stacked on top of
              one another on a dense series. `visual_series/3` bounds how many
              samples a line offers; the table alternative lists every bucket. --%>
        <div class="pointer-events-none absolute inset-x-0 bottom-0 h-target-min">
          <div
            :for={{item, index, left, width} <- point_regions(@data)}
            class="group pointer-events-none absolute inset-y-0 overflow-visible hover:z-10 focus-within:z-20"
            style={region_style(left, width, index, length(@data))}
            data-display-point-x={Map.get(item, :x)}
            data-display-region={"#{left} #{width}"}
          >
            <button
              type="button"
              class="pointer-events-auto absolute inset-x-0 bottom-0 min-h-target-min -translate-y-1/2 cursor-pointer border border-transparent bg-transparent focus-visible:border-focus focus-visible:outline-2 focus-visible:outline-offset-1 aria-pressed:border-focus"
              data-display-point="true"
              data-touch-tooltip="true"
              tabindex={point_tabindex(index)}
              aria-label={item_aria(item, @unit)}
            ><span class="sr-only">{item_aria(item, @unit)}</span></button>
            <span
              role="tooltip"
              aria-hidden="true"
              class={[
                "pointer-events-none absolute bottom-full z-30 hidden w-max max-w-[min(18rem,calc(100vw-2rem))] whitespace-normal break-words rounded-control-sm border border-border-default bg-surface-raised px-2 py-1 text-tooltip text-text-primary shadow-overlay group-focus-within:block group-hover:block",
                tooltip_position_class(index, length(@data))
              ]}
            >
              {item_tooltip(item, @unit)}
            </span>
          </div>
        </div>
      </div>

      <%!-- Date ticks under the plot, one per caller-chosen bucket, each on
            the x of the reading it names. The ends hug the plot's own edges
            so no label spills past the card. --%>
      <div
        :if={@kind in [:step, :wave, :line] and @x_labels != []}
        class="relative mt-2 h-4 font-mono text-[10.5px] text-text-tertiary"
        aria-hidden="true"
        data-display-x-labels="true"
      >
        <span
          :for={{tick, index} <- Enum.with_index(@x_labels)}
          class={[
            "absolute top-0 whitespace-nowrap",
            rem(index, 2) == 1 && "hidden sm:inline",
            x_label_class(index, length(@x_labels), Map.get(tick, :position))
          ]}
          style={"left: #{Map.get(tick, :position)}%"}
        >
          {Map.get(tick, :label)}
        </span>
      </div>

      <div :if={@kind in [:stacked, :proportional_meter]} class="grid gap-2">
        <div class="relative">
          <div
            aria-hidden="true"
            class={[
              "flex h-4 overflow-hidden bg-surface-sunken",
              if(@kind == :proportional_meter, do: "h-2 rounded-dot", else: "h-3 rounded-[3px]")
            ]}
          >
            <span
              :for={item <- @data}
              :if={item_style(item, :width)}
              class={[
                "min-w-0 border-r border-surface-raised last:border-r-0",
                tone_class(item_tone(item))
              ]}
              style={item_style(item, :width)}
            ></span>
          </div>
          <div class="pointer-events-none absolute inset-0 flex">
            <div
              :for={{item, index} <- Enum.with_index(@data)}
              :if={item_style(item, :width)}
              class="group relative min-w-0"
              style={item_style(item, :width)}
            >
              <button
                type="button"
                class="pointer-events-auto absolute inset-x-0 top-1/2 min-h-target-min -translate-y-1/2 cursor-pointer rounded-tick border border-transparent bg-transparent focus-visible:border-focus focus-visible:outline-2 focus-visible:outline-offset-1 aria-pressed:border-focus"
                data-display-point="true"
                data-touch-tooltip="true"
                tabindex={point_tabindex(index)}
                aria-label={item_aria(item, @unit)}
              ><span class="sr-only">{item_aria(item, @unit)}</span></button>
              <span
                role="tooltip"
                aria-hidden="true"
                class={[
                  "pointer-events-none absolute bottom-full z-10 hidden w-max max-w-[min(18rem,calc(100vw-2rem))] whitespace-normal break-words rounded-control-sm border border-border-default bg-surface-raised px-2 py-1 text-tooltip text-text-primary shadow-overlay group-focus-within:block group-hover:block",
                  tooltip_position_class(index, length(@data))
                ]}
              >
                {item_tooltip(item, @unit)}
              </span>
            </div>
          </div>
        </div>
        <div class="grid gap-1">
          <div
            :for={item <- @data}
            class="flex items-center justify-between gap-2 text-data text-text-secondary"
          >
            <span>{item_label(item)}</span>
            <span>{item_value(item, @unit)}</span>
          </div>
        </div>
      </div>

      <div :if={@kind == :histogram} class="flex h-16 items-end gap-0.5 overflow-visible">
        <div
          :for={{item, index} <- Enum.with_index(@data)}
          class="group relative flex h-full min-w-0 flex-1 items-end hover:z-10 focus-within:z-20"
        >
          <span
            aria-hidden="true"
            class={["absolute inset-x-0 bottom-0 rounded-t-tick", tone_class(item_tone(item))]}
            style={item_style(item, :height) || "height: 2px"}
          ></span>
          <button
            type="button"
            class="absolute inset-x-0 bottom-0 min-h-target-min cursor-pointer rounded-t-tick border border-transparent bg-transparent focus-visible:border-focus focus-visible:outline-2 focus-visible:outline-offset-1 aria-pressed:border-focus"
            data-display-point="true"
            data-touch-tooltip="true"
            tabindex={point_tabindex(index)}
            aria-label={item_aria(item, @unit)}
          ><span class="sr-only">{item_aria(item, @unit)}</span></button>
          <span
            role="tooltip"
            aria-hidden="true"
            class="pointer-events-none absolute bottom-full left-1/2 z-10 hidden -translate-x-1/2 whitespace-nowrap rounded-control-sm border border-border-default bg-surface-raised px-2 py-1 text-data text-text-primary shadow-overlay group-focus-within:block group-hover:block"
          >
            {item_tooltip(item, @unit)}
          </span>
        </div>
      </div>

      <div :if={@kind == :ranked_bar} class="grid gap-2">
        <div
          :for={{item, index} <- Enum.with_index(@data)}
          class="grid grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-2 text-data"
        >
          <span class="w-5 text-text-tertiary">{Map.get(item, :rank) || index + 1}</span>
          <div class="group relative min-w-0">
            <span
              aria-hidden="true"
              class={["block min-h-target-min rounded-dot", tone_class(item_tone(item))]}
              style={item_style(item, :width)}
            ></span>
            <button
              type="button"
              class="absolute left-0 top-1/2 min-h-target-min min-w-target-min -translate-y-1/2 cursor-pointer rounded-dot border border-transparent bg-transparent text-left focus-visible:border-focus focus-visible:outline-2 focus-visible:outline-offset-1 aria-pressed:border-focus"
              style={item_style(item, :width)}
              data-display-point="true"
              data-touch-tooltip="true"
              tabindex={point_tabindex(index)}
              aria-label={item_aria(item, @unit)}
            ><span class="sr-only">{item_aria(item, @unit)}</span></button>
            <span
              role="tooltip"
              aria-hidden="true"
              class="pointer-events-none absolute bottom-full left-1/2 z-10 hidden -translate-x-1/2 whitespace-nowrap rounded-control-sm border border-border-default bg-surface-raised px-2 py-1 text-data text-text-primary shadow-overlay group-focus-within:block group-hover:block"
            >
              {item_tooltip(item, @unit)}
            </span>
          </div>
          <span class="text-text-secondary">{item_value(item, @unit)}</span>
        </div>
      </div>

      <div :if={@kind == :day_grid} class="grid grid-cols-7 gap-1">
        <div :for={{item, index} <- Enum.with_index(@data)} class="group relative min-w-0">
          <span
            aria-hidden="true"
            class={[
              "block aspect-square min-h-target-min w-full rounded-tick",
              tone_class(item_tone(item))
            ]}
          ></span>
          <button
            type="button"
            class="absolute inset-0 min-h-target-min min-w-target-min cursor-pointer rounded-tick border border-transparent bg-transparent focus-visible:border-focus focus-visible:outline-2 focus-visible:outline-offset-1 aria-pressed:border-focus"
            data-display-point="true"
            data-touch-tooltip="true"
            tabindex={point_tabindex(index)}
            aria-label={item_aria(item, @unit)}
          ><span class="sr-only">{item_aria(item, @unit)}</span></button>
          <span
            role="tooltip"
            aria-hidden="true"
            class="pointer-events-none absolute bottom-full left-1/2 z-10 hidden -translate-x-1/2 whitespace-nowrap rounded-control-sm border border-border-default bg-surface-raised px-2 py-1 text-data text-text-primary shadow-overlay group-focus-within:block group-hover:block"
          >
            {item_tooltip(item, @unit)}
          </span>
        </div>
      </div>
    </div>
    """
  end

  # From `sm` up the plot's own points carry every value and the table stays
  # an assistive alternative. Below `sm` a 24-bucket plot is 13px per bucket,
  # too narrow for a finger, so the same table becomes a visible disclosure:
  # the dependable narrow-screen path the audit asks for.
  defp data_table(%{assistive: true} = assigns) do
    ~H"""
    <div id={@id} class="sr-only hidden sm:block">
      <table>
        <thead>
          <tr>
            <th :for={column <- @columns} scope="col">{column}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows}>
            <td :for={cell <- row_cells(row)}>{cell}</td>
          </tr>
        </tbody>
      </table>
    </div>
    <details id={"#{@id}-narrow"} class="mt-3 border-t border-border-subtle sm:hidden">
      <summary class="h-control-md cursor-pointer py-2 text-label font-medium text-text-primary focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus">
        View data table
      </summary>
      <div class="overflow-x-auto">
        <table class="w-full text-left text-data text-text-secondary">
          <thead class="bg-surface-sunken text-text-primary">
            <tr>
              <th :for={column <- @columns} scope="col" class="px-3 py-2 font-semibold">
                {column}
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows} class="border-t border-border-subtle">
              <td :for={cell <- row_cells(row)} class="px-3 py-2">{cell}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </details>
    """
  end

  defp data_table(assigns) do
    assigns = assign(assigns, :resolved_columns, assigns.columns)

    ~H"""
    <%!-- No border of its own: this disclosure always opens inside a panel that
          already has one, and a bordered box inside a bordered box is the
          console's one hard layout ban. A top hairline carries the separation. --%>
    <details id={@id} class="mt-3 border-t border-border-subtle">
      <summary class="h-control-md cursor-pointer py-2 text-label font-medium text-text-primary focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus">
        View data table
      </summary>
      <div class="overflow-x-auto">
        <table class="w-full text-left text-data text-text-secondary">
          <thead class="bg-surface-sunken text-text-primary">
            <tr>
              <th :for={column <- @resolved_columns} scope="col" class="px-3 py-2 font-semibold">
                {column}
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows} class="border-t border-border-subtle">
              <td :for={cell <- row_cells(row)} class="px-3 py-2">{cell}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </details>
    """
  end

  defp validate_full_table!(%{variant: :full, data: _data, table_rows: rows})
       when rows not in [nil, []] do
    raise ArgumentError,
          "full data displays do not accept arbitrary table_rows; use canonical table_cells"
  end

  defp validate_full_table!(%{variant: :full, data: data, table_columns: []})
       when data != [] do
    raise ArgumentError,
          "full data displays require table_columns for the exact table alternative"
  end

  defp validate_full_table!(%{variant: :full, data: data, table_columns: columns})
       when data != [] do
    unless Enum.all?(data, &canonical_table_record?(&1, length(columns))) do
      raise ArgumentError,
            "full data displays require canonical data records with table_cells matching table_columns"
    end
  end

  defp validate_full_table!(_assigns), do: :ok

  defp canonical_table_record?(record, column_count) when is_map(record) do
    cells = Map.get(record, :table_cells)
    is_list(cells) and length(cells) == column_count
  end

  defp canonical_table_record?(_record, _column_count), do: false

  defp canonical_table_rows(data) do
    Enum.map(data, fn record ->
      %{
        id: Map.get(record, :id) || Map.get(record, :label),
        cells: Map.fetch!(record, :table_cells)
      }
    end)
  end

  defp resolve_table(%{data: []}) do
    {[], []}
  end

  defp resolve_table(%{data: data, table_columns: columns}) when columns != [] do
    if Enum.all?(data, &canonical_table_record?(&1, length(columns))) do
      {canonical_table_rows(data), columns}
    else
      {fallback_table_rows(data), columns}
    end
  end

  defp resolve_table(%{variant: :full}) do
    {[], []}
  end

  defp resolve_table(%{data: data}) do
    {fallback_table_rows(data), ["Label", "Value"]}
  end

  defp fallback_table_rows(data) do
    Enum.map(data, fn record ->
      cells =
        Map.get(record, :table_cells) ||
          [item_label(record), item_value(record, nil)]

      %{
        id: Map.get(record, :id) || Map.get(record, :label),
        cells: cells
      }
    end)
  end

  defp visual_series(:ticks, :compact, data), do: downsample_series(data, @compact_tick_cap)
  defp visual_series(:ticks, _variant, data), do: downsample_series(data, @full_tick_cap)
  defp visual_series(:bucket_bar, :compact, data), do: downsample_series(data, @full_tick_cap)

  # A line's shape comes from its path, not from its focus targets. The
  # targets exist so a pointer or a keyboard can read individual values, and
  # a bounded, evenly spaced set of real samples does that; a target per
  # bucket on a 168-bucket series would be 168 tab stops two pixels wide.
  #
  # A `:full` plot is the primary answer on its screen and gets the same
  # allowance as a full tick strip, which is enough for a day of hourly
  # readings to keep one target each. A `:compact` strip beside a number keeps
  # the tighter bound. Each sample stays a real record, never a merged summary
  # of its neighbours, and the table lists every bucket either way.
  defp visual_series(kind, :compact, data) when kind in [:step, :wave, :line],
    do: sample_series(data, @line_sample_cap)

  defp visual_series(kind, _variant, data) when kind in [:step, :wave, :line],
    do: sample_series(data, @full_tick_cap)

  defp visual_series(_kind, _variant, data), do: data

  # The normalized x is stamped from the record's position in the *full*
  # series, before any sample is dropped, so a kept sample still names the
  # place on the path where its own value is drawn.
  defp sample_series([], _cap), do: []

  defp sample_series(items, cap) when is_list(items) do
    last = max(length(items) - 1, 1)

    placed =
      items
      |> Enum.with_index()
      |> Enum.map(fn {item, index} ->
        Map.put(item, :x, Float.round(index / last * 100, 2))
      end)

    if length(items) <= cap, do: placed, else: take_samples(placed, cap)
  end

  defp take_samples(items, cap) do
    last = length(items) - 1
    wanted = MapSet.new(0..(cap - 1), fn step -> round(step * last / (cap - 1)) end)

    items
    |> Enum.with_index()
    |> Enum.filter(fn {_item, index} -> MapSet.member?(wanted, index) end)
    |> Enum.map(&elem(&1, 0))
  end

  # A target owns the span between the midpoints to its neighbours, so the
  # nearest plotted reading always wins a hit and no two targets overlap. The
  # first and last reach the edges of the plot.
  defp point_regions(data) do
    xs = Enum.map(data, &point_x/1)
    count = length(xs)

    xs
    |> Enum.with_index()
    |> Enum.map(fn {x, index} ->
      left = if index == 0, do: 0.0, else: (Enum.at(xs, index - 1) + x) / 2
      right = if index == count - 1, do: 100.0, else: (x + Enum.at(xs, index + 1)) / 2

      {Enum.at(data, index), index, Float.round(left, 2), Float.round(right - left, 2)}
    end)
  end

  defp point_x(%{x: x}) when is_number(x), do: x * 1.0
  defp point_x(_item), do: 0.0

  # The first and last samples sit on the plot's own edges, so their
  # nearest-point span is only half as wide as an interior one. They reach
  # `@edge_outset` into the card's gutter beside the plot, which leaves every
  # interior boundary on its midpoint and keeps the end targets hittable on a
  # narrow screen.
  defp region_style(_left, width, 0, _count),
    do: "left: -#{@edge_outset}px; width: calc(#{width}% + #{@edge_outset}px)"

  defp region_style(left, width, index, count) when index == count - 1,
    do: "left: #{left}%; width: calc(#{width}% + #{@edge_outset}px)"

  defp region_style(left, width, _index, _count), do: "left: #{left}%; width: #{width}%"

  defp downsample_series(items, cap) when is_list(items) and length(items) <= cap, do: items

  defp downsample_series(items, cap) when is_list(items) and cap > 0 do
    chunk_size = ceil(length(items) / cap)

    items
    |> Enum.chunk_every(chunk_size)
    |> Enum.map(&merge_series_chunk/1)
  end

  defp downsample_series(items, _cap), do: items

  defp merge_series_chunk([item]), do: item

  defp merge_series_chunk(items) do
    worst = Enum.max_by(items, &series_rank/1)
    first = List.first(items)
    last = List.last(items)
    count = length(items)

    worst
    |> Map.put(:id, Map.get(first, :id) || Map.get(first, :label))
    |> Map.put(
      :tooltip,
      "#{count} windows, #{item_label(first)} to #{item_label(last)}, worst #{item_label(worst)}"
    )
    |> Map.put(
      :aria_label,
      "#{count} windows, worst #{item_label(worst)}"
    )
  end

  defp series_rank(item) do
    case item_tone(item) do
      tone when tone in [:down, "down", :error, "error"] ->
        6

      tone when tone in [:anomaly, "anomaly"] ->
        5

      tone
      when tone in [:slow, "slow", :late, "late", :warning, "warning", :degraded, "degraded"] ->
        4

      tone when tone in [:paused, "paused"] ->
        3

      tone when tone in [:missing, "missing", :partial, "partial", :no_latency, "no_latency"] ->
        2

      _ ->
        1
    end
  end

  defp hide_axis?(:ticks, :compact), do: true
  defp hide_axis?(_kind, _variant), do: false

  defp x_label_class(0, _count, position) when position <= 2, do: "translate-x-0"

  defp x_label_class(index, count, position) when index == count - 1 and position >= 98,
    do: "-translate-x-full"

  defp x_label_class(_index, _count, _position), do: "-translate-x-1/2"

  # The axis hint is read by whoever is looking at the plot, so it names the
  # unit and nothing else. "Zero-based" is a claim about how the chart was
  # drawn, not a value: it belongs in each display's `description`, which
  # assistive technology reads and a reviewer can audit.
  # A caller that writes its own `:mid` has said what the middle of its axis
  # means (which mark is the comparison period, and in which vocabulary). The
  # unit is the fallback for the callers that have not.
  defp axis_hint(:histogram, _unit, _range), do: "requests per bucket"

  defp axis_hint(_kind, unit, range) do
    Map.get(range, :mid) || if(is_binary(unit), do: unit, else: "")
  end

  defp visual_container_class(_kind), do: "min-w-0 overflow-visible"

  # Literal class strings keep every supported plot tier visible to Tailwind.
  # Each state uses the same height, so loading and empty plots never shift the
  # card when readings arrive.
  defp plot_class(:hero), do: "h-60 sm:h-64 lg:h-80"
  defp plot_class(:tall), do: "h-40 lg:h-[248px]"
  defp plot_class(_standard), do: "h-30 lg:h-40"

  defp min_plot_class(:hero), do: "min-h-60 sm:min-h-64 lg:min-h-80"
  defp min_plot_class(:tall), do: "min-h-40 lg:min-h-[248px]"
  defp min_plot_class(_standard), do: "min-h-30 lg:min-h-40"

  defp empty_slot_class(:hero), do: "min-h-60 sm:min-h-64 lg:min-h-80"
  defp empty_slot_class(:tall), do: "min-h-40 lg:min-h-[248px]"
  defp empty_slot_class(_standard), do: "min-h-30 lg:min-h-40"

  defp tooltip_position_class(index, count) when count <= 1 or index * 3 < count,
    do: "left-0 translate-x-0"

  defp tooltip_position_class(index, count) when (index + 1) * 3 > count * 2,
    do: "right-0 translate-x-0"

  defp tooltip_position_class(_index, _count), do: "left-1/2 -translate-x-1/2"

  # `line_class` carries both the stroke and fill utility for a line/wave
  # chart's single series (e.g. "stroke-status-live fill-status-live", or an
  # arbitrary-value override for a percentile ramp). Each `<path>` needs only
  # its own half.
  defp stroke_only(line_class) do
    line_class |> String.split() |> Enum.filter(&String.starts_with?(&1, "stroke-"))
  end

  defp fill_only(line_class) do
    line_class |> String.split() |> Enum.filter(&String.starts_with?(&1, "fill-"))
  end

  defp tone_class(tone) when tone in [:up, "up", :live, "live", :success, "success"],
    do: "bg-status-live"

  defp tone_class(tone) when tone in [:slow, "slow", :late, "late", :warning, "warning"],
    do: "bg-status-late"

  defp tone_class(tone) when tone in [:down, "down", :error, "error", :anomaly, "anomaly"],
    do: "bg-status-error"

  defp tone_class(tone) when tone in [:paused, "paused"], do: "bg-status-paused"

  defp tone_class(tone) when tone in [:emphasis, "emphasis", :volume, "volume", :brand, "brand"],
    do: "bg-brand-mark"

  defp tone_class(tone) when tone in [:latency, "latency", :p50, "p50"], do: "bg-chart-p50"

  defp tone_class(_tone), do: "bg-status-neutral"

  defp item_tone(item), do: Map.get(item, :tone) || Map.get(item, :state) || Map.get(item, :kind)

  # Roving tabindex: the first point is the plot's one Tab stop and the hook
  # moves it as the reader arrows through the series.
  defp point_tabindex(0), do: "0"
  defp point_tabindex(_index), do: "-1"

  # A bucket that carries `segments` draws them stacked, worst on top of the
  # baseline, each `%{tone: tone, ratio: 0..1}` sized by its share.
  defp item_segments(item) do
    case Map.get(item, :segments) do
      segments when is_list(segments) -> Enum.filter(segments, &(segment_ratio(&1) > 0))
      _other -> []
    end
  end

  defp segment_ratio(%{ratio: ratio}) when is_number(ratio), do: max(min(ratio, 1), 0) * 1.0
  defp segment_ratio(_segment), do: 0.0

  defp segment_height(segment), do: Float.round(segment_ratio(segment) * 100, 2)

  # A bucket still being measured (the current hour or day) is drawn hatched
  # so a low reading at the right edge is never mistaken for a collapse.
  defp item_in_progress?(item), do: Map.get(item, :in_progress?, false) == true

  defp row_cells(%{cells: cells}) when is_list(cells), do: cells

  defp item_label(item), do: Map.get(item, :label) || Map.get(item, :name) || "Value"

  defp item_value(item, unit) do
    value = Map.get(item, :value) || Map.get(item, :count) || Map.get(item, :ratio)
    if is_nil(value), do: "", else: format_value(value, unit)
  end

  defp item_aria(item, unit) do
    Map.get(item, :aria_label) || Map.get(item, "aria_label") || item_tooltip(item, unit)
  end

  defp item_tooltip(item, unit) do
    Map.get(item, :tooltip) || Map.get(item, "tooltip") || default_item_aria(item, unit)
  end

  defp default_item_aria(item, unit), do: "#{item_label(item)}, #{item_value(item, unit)}"

  defp format_value(value, nil), do: to_string(value)
  defp format_value(value, unit), do: "#{value} #{unit}"

  defp item_style(item, key) do
    case Map.get(item, key) do
      nil -> nil
      value when is_binary(value) -> value
      value -> "#{key}: #{value}%"
    end
  end

  # "Measured" is the caller's own fact when it states one. A bucket series
  # that predates the flag keeps the old reading of a missing height: no
  # height, no measurement.
  defp item_measured?(item),
    do: Map.get(item, :measured?, not is_nil(Map.get(item, :height)))

  defp bar_style(item) do
    if zero_height?(Map.get(item, :height)),
      do: "height: 2px",
      else: item_style(item, :height)
  end

  defp zero_height?(value) when is_number(value), do: value <= 0
  defp zero_height?(_value), do: false

  # The cap's own 2px straddles the value it names, so a reading at the floor
  # still sits on the floor rather than half a pixel under it.
  defp reference_style(item) do
    case Map.get(item, :reference_height) do
      nil -> nil
      value when is_binary(value) -> value
      value when is_number(value) and value <= 0 -> "bottom: 0px"
      value -> "bottom: calc(#{value}% - 1px)"
    end
  end

  defp state_text_class(:anomaly), do: "text-status-error-ink"

  defp state_dot_class(:anomaly), do: "bg-status-error"

  defp state_notice_class(:disabled),
    do: "border-border-default bg-surface-sunken text-text-secondary"

  defp state_notice_class(:permission),
    do: "border-status-neutral-border bg-status-neutral-bg text-status-neutral-ink"

  defp state_notice_class(:unavailable),
    do: "border-status-error-border bg-status-error-bg text-status-error-ink"

  defp state_notice_icon(:disabled), do: "hero-pause-circle"
  defp state_notice_icon(:permission), do: "hero-lock-closed"
  defp state_notice_icon(:unavailable), do: "hero-exclamation-triangle"

  defp state_message(:anomaly), do: "Anomalous values need review"
  defp state_message(:disabled), do: "This data is disabled."
  defp state_message(:permission), do: "You do not have permission to view this data."
  defp state_message(:unavailable), do: "This data is temporarily unavailable. Try again."
end
