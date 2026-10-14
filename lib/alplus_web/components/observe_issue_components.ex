defmodule AlplusWeb.ObserveIssueComponents do
  @moduledoc """
  Markup for one Observe issue's detail screen.

  `AlplusWeb.ObserveIssueLive` keeps mount, event handling, and assign
  building; every section of `render/1` composes these function components.
  Evidence topics (stack trace, request, breadcrumbs, tags, ...) read as
  article sections inside one data panel (`evidence_block/1`). Hairlines and
  spacing carry hierarchy; nested bordered cards do not.

  Only the stack trace and the request stay open by default. Everything else
  is supporting evidence a reader opts into, so it renders as a closed
  disclosure and the screen keeps one answer at the top.
  """

  use AlplusWeb, :html

  import AlplusWeb.Format
  import AlplusWeb.Observe.Display

  import AlplusWeb.Observe.Evidence, only: [stack_frames: 1, breadcrumb_line: 1]

  alias Alplus.Observe.Release
  alias Alplus.Observe.EvidenceScrubber
  alias AlplusWeb.Observe.Evidence

  @max_evidence_bytes 32_000

  @doc "The banner shown when this issue is merged into another one."
  attr :org_token, :string, required: true
  attr :project, :any, required: true
  attr :merged_parent, :any, default: nil

  def merged_banner(assigns) do
    ~H"""
    <div
      :if={@merged_parent}
      id="observe-issue-merged-banner"
      class="rounded-control border border-status-neutral-border bg-status-neutral-bg p-4 text-body text-status-neutral-ink"
    >
      <div class="flex items-start gap-3">
        <.icon name="hero-arrow-path" class="mt-0.5 size-5 shrink-0" />
        <p>
          This issue is merged into <.link
            navigate={
              ~p"/dashboard/orgs/#{@org_token}/projects/#{@project.public_token}/observe/issues/#{@merged_parent.id}"
            }
            class="font-medium underline"
          >
        {@merged_parent.title}
      </.link>. New occurrences count toward that issue.
        </p>
      </div>
    </div>
    """
  end

  @doc "Level/status badges, the one-line impact answer, and the diagnosis card."
  attr :issue, :any, required: true
  attr :selected_occurrence, :any, required: true
  attr :issue_presentation, :any, required: true
  attr :group_event_count, :integer, required: true
  attr :users_affected, :integer, required: true
  attr :latest_release, :any, default: nil
  attr :resolved_release, :any, default: nil
  attr :members, :list, default: []

  def issue_header(assigns) do
    ~H"""
    <section id="observe-issue-header" class="min-w-0">
      <div class="flex min-w-0 flex-col gap-3">
        <div class="flex flex-wrap items-center gap-2">
          <.status_badge
            tone={level_tone(@issue.level)}
            label={String.capitalize(@issue.level)}
          />
          <.status_badge tone={status_tone(@issue.status)} label={status_label(@issue.status)} />
          <.status_badge
            :if={Evidence.unhandled?(@selected_occurrence)}
            tone="error"
            label="Unhandled"
          />
        </div>
        <p
          :if={@issue.culprit || @issue_presentation.recovery_steps == []}
          id="observe-issue-culprit"
          class={[
            "max-w-prose break-words text-text-secondary",
            if(@issue.culprit, do: "font-mono text-data", else: "text-caption")
          ]}
        >
          {@issue.culprit || "No cause identified yet."}
        </p>
        <p id="observe-issue-impact" class="text-heading-02 font-semibold text-text-primary">
          {issue_impact_answer(@group_event_count, @issue.first_seen_at, @users_affected)}
        </p>
      </div>

      <%!-- Four facts on one grid: two columns on a phone, four from
            `sm`, no fixed widths, so nothing clips at 390px. --%>
      <dl
        id="observe-issue-context-row"
        class="mt-4 grid grid-cols-2 gap-px border-y border-border-default bg-border-subtle sm:grid-cols-4"
      >
        <div class="min-w-0 bg-surface-raised px-4 py-3">
          <dt class="text-label font-medium text-text-tertiary">First seen</dt>
          <dd id="observe-issue-first-seen">
            <.timestamp
              at={@issue.first_seen_at}
              class="mt-1 block text-data tabular-nums text-text-primary"
            />
          </dd>
        </div>
        <div class="min-w-0 bg-surface-raised px-4 py-3">
          <dt class="text-label font-medium text-text-tertiary">Last seen</dt>
          <dd id="observe-issue-last-seen">
            <.timestamp
              at={@issue.last_seen_at}
              class="mt-1 block text-data tabular-nums text-text-primary"
            />
          </dd>
        </div>
        <div id="observe-issue-release" class="min-w-0 bg-surface-raised px-4 py-3">
          <dt class="text-label font-medium text-text-tertiary">Release</dt>
          <dd class="mt-1 break-words text-data text-text-primary">
            {release_label(@issue, @latest_release, @resolved_release)}
          </dd>
        </div>
        <div id="observe-issue-assignment" class="min-w-0 bg-surface-raised px-4 py-3">
          <dt class="text-label font-medium text-text-tertiary">Assignment</dt>
          <dd class="mt-1 break-words text-data text-text-primary">
            {Evidence.assignee_label(@members, @issue.assignee_id)}
          </dd>
        </div>
      </dl>

      <.section_card
        :if={@issue_presentation.recovery_steps != []}
        id="observe-issue-diagnosis"
        title="Fix the socket origin"
        description={@issue_presentation.summary}
        class="mt-4"
      >
        <ol class="divide-y divide-border-subtle">
          <li
            :for={{step, index} <- Enum.with_index(@issue_presentation.recovery_steps, 1)}
            class="flex gap-3 py-3 first:pt-0 last:pb-0"
          >
            <span
              aria-hidden="true"
              class="flex size-6 shrink-0 items-center justify-center rounded-dot bg-status-error-bg text-label font-semibold text-status-error-ink"
            >
              {index}
            </span>
            <p class="min-w-0 pt-0.5 text-body text-text-primary">{step}</p>
          </li>
        </ol>
        <details
          id="observe-issue-technical-details"
          class="mt-4 border-t border-border-subtle pt-3"
        >
          <summary class="inline-flex min-h-target-min cursor-pointer items-center py-1 text-label font-medium text-text-secondary focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus">
            Technical details
          </summary>
          <p class="mt-2 break-words font-mono text-data text-text-primary">
            {@issue_presentation.technical_details}
          </p>
        </details>
      </.section_card>
    </section>
    """
  end

  @doc "The Comments tab panel."
  attr :issue_tab, :string, required: true
  attr :comments, :list, required: true
  attr :comments_more?, :boolean, required: true

  def comments_panel(assigns) do
    ~H"""
    <section
      id="observe-issue-comments"
      role="tabpanel"
      aria-labelledby="observe-issue-tabs-tab-comments"
      hidden={@issue_tab != "comments"}
      aria-hidden={to_string(@issue_tab != "comments")}
      class="flex flex-col gap-stack"
    >
      <.data_panel
        :if={@issue_tab == "comments"}
        id="observe-issue-comments-panel"
        title="Comments"
      >
        <p
          :if={@comments == []}
          id="observe-issue-comments-empty"
          class="px-4 py-5 text-body text-text-secondary"
        >
          No comments yet.
        </p>
        <ol :if={@comments != []} class="divide-y divide-border-subtle">
          <li
            :for={comment <- @comments}
            id={"observe-issue-comment-#{comment.id}"}
            class="px-4 py-4"
          >
            <p class="flex flex-wrap items-baseline gap-x-2 text-data text-text-secondary">
              <span class="font-medium text-text-primary">
                {Evidence.member_display_name(comment.author)}
              </span>
              <time class="tabular-nums" title={format_utc(comment.inserted_at)}>
                {Evidence.relative_time(comment.inserted_at)}
              </time>
            </p>
            <p class="mt-2 text-pretty text-body text-text-primary">{comment.body}</p>
          </li>
        </ol>
        <div :if={@comments_more?} class="border-t border-border-subtle px-4 py-3">
          <.button
            id="observe-issue-comments-load-more"
            type="button"
            variant="secondary"
            phx-click="load_more_comments"
          >
            Load more comments
          </.button>
        </div>
      </.data_panel>
    </section>
    """
  end

  @doc "The User reports tab panel."
  attr :issue_tab, :string, required: true
  attr :user_reports, :list, required: true
  attr :reports_more?, :boolean, required: true

  def reports_panel(assigns) do
    ~H"""
    <section
      id="observe-issue-reports"
      role="tabpanel"
      aria-labelledby="observe-issue-tabs-tab-reports"
      hidden={@issue_tab != "reports"}
      aria-hidden={to_string(@issue_tab != "reports")}
      class="flex flex-col gap-stack"
    >
      <.data_panel
        :if={@issue_tab == "reports"}
        id="observe-issue-reports-panel"
        title="User reports"
      >
        <p
          :if={@user_reports == []}
          id="observe-issue-reports-empty"
          class="px-4 py-5 text-body text-text-secondary"
        >
          No user reports yet.
        </p>
        <ol :if={@user_reports != []} class="divide-y divide-border-subtle">
          <li
            :for={report <- @user_reports}
            id={"observe-issue-report-#{report.id}"}
            class="px-4 py-4"
          >
            <p class="text-data text-text-secondary">
              <span class="font-medium text-text-primary">{report.name || "Unnamed"}</span>
              <span :if={report.email}>[REDACTED]</span>
            </p>
            <p class="mt-2 text-pretty text-body text-text-primary">{report.comments}</p>
          </li>
        </ol>
        <div :if={@reports_more?} class="border-t border-border-subtle px-4 py-3">
          <.button
            id="observe-issue-reports-load-more"
            type="button"
            variant="secondary"
            phx-click="load_more_reports"
          >
            Load more reports
          </.button>
        </div>
      </.data_panel>
    </section>
    """
  end

  @doc "The Evidence tab panel: everything about the selected occurrence."
  attr :issue_tab, :string, required: true
  attr :issue, :any, required: true
  attr :selected_occurrence, :any, default: nil
  attr :occurrences, :list, required: true
  attr :occurrence_columns, :list, required: true
  attr :stack_order, :atom, required: true
  attr :stack_view, :atom, required: true
  attr :stack_in_app_only, :boolean, required: true
  attr :merged_children, :list, required: true
  attr :merged_children_count, :integer, required: true
  attr :merged_children_more?, :boolean, required: true
  attr :full_payload, :any, default: nil
  attr :full_payload_error, :any, default: nil
  attr :full_payload_loading?, :boolean, required: true
  attr :org_token, :string, required: true
  attr :project, :any, required: true

  def event_panel(assigns) do
    ~H"""
    <section
      id="observe-issue-event"
      role="tabpanel"
      aria-labelledby="observe-issue-tabs-tab-event"
      hidden={@issue_tab != "event"}
      aria-hidden={to_string(@issue_tab != "event")}
    >
      <div :if={@issue_tab == "event"} class="min-w-0">
        <.data_panel id="observe-issue-evidence" title="Event evidence">
          <div :if={@selected_occurrence} class="flex flex-col gap-stack">
            <.event_context issue={@issue} selected_occurrence={@selected_occurrence} />
            <.event_highlights selected_occurrence={@selected_occurrence} />
            <.event_actions
              issue={@issue}
              occurrences={@occurrences}
              selected_occurrence={@selected_occurrence}
            />
            <.user_block selected_occurrence={@selected_occurrence} />
            <.request_block selected_occurrence={@selected_occurrence} />
            <.stacktrace_block
              selected_occurrence={@selected_occurrence}
              stack_order={@stack_order}
              stack_view={@stack_view}
              stack_in_app_only={@stack_in_app_only}
            />
            <.causes_block selected_occurrence={@selected_occurrence} />
            <.context_block issue={@issue} selected_occurrence={@selected_occurrence} />
            <.breadcrumbs_block selected_occurrence={@selected_occurrence} />
            <.tags_block
              issue={@issue}
              org_token={@org_token}
              project={@project}
              selected_occurrence={@selected_occurrence}
            />
            <.occurrences_block
              occurrences={@occurrences}
              occurrence_columns={@occurrence_columns}
              selected_occurrence={@selected_occurrence}
            />
            <.full_payload_block
              selected_occurrence={@selected_occurrence}
              full_payload={@full_payload}
              full_payload_error={@full_payload_error}
              full_payload_loading?={@full_payload_loading?}
            />
          </div>

          <.no_context_block issue={@issue} selected_occurrence={@selected_occurrence} />
          <.merged_children_block
            merged_children={@merged_children}
            merged_children_count={@merged_children_count}
            merged_children_more?={@merged_children_more?}
            org_token={@org_token}
            project={@project}
          />
        </.data_panel>
      </div>
    </section>
    """
  end

  attr :issue, :any, required: true
  attr :selected_occurrence, :any, required: true

  defp event_context(assigns) do
    ~H"""
    <dl
      id="observe-issue-event-context"
      class="flex flex-wrap gap-x-6 gap-y-2 border-b border-border-subtle px-4 pb-4"
    >
      <div class="min-w-0 max-w-full">
        <dt class="text-label font-medium text-text-tertiary">Occurrence</dt>
        <dd class="flex min-w-0 items-center gap-2 font-mono text-data text-text-primary">
          <span
            id="observe-issue-occurrence-id"
            class="min-w-0 max-w-56 truncate"
            title={@selected_occurrence.event_id}
          >
            {@selected_occurrence.event_id}
          </span>
          <.copy_button target="observe-issue-occurrence-id" label="Copy" />
        </dd>
      </div>
      <div class="min-w-0">
        <dt class="text-label font-medium text-text-tertiary">Received</dt>
        <dd class="font-mono text-data text-text-primary">
          <.timestamp at={@selected_occurrence.received_at} />
        </dd>
      </div>
      <div class="min-w-0 max-w-full">
        <dt class="text-label font-medium text-text-tertiary">Issue</dt>
        <dd class="flex min-w-0 items-center gap-2 font-mono text-data text-text-primary">
          <span
            id="observe-issue-id"
            class="min-w-0 max-w-56 truncate"
            title={@issue.id}
          >
            {@issue.id}
          </span>
          <.copy_button target="observe-issue-id" label="Copy" />
        </dd>
      </div>
      <div :if={@issue.environment} class="min-w-0">
        <dt class="text-label font-medium text-text-tertiary">Environment</dt>
        <dd class="font-mono text-data text-text-primary">{@issue.environment}</dd>
      </div>
    </dl>
    """
  end

  attr :selected_occurrence, :any, required: true

  defp event_highlights(assigns) do
    ~H"""
    <div
      :if={Evidence.highlight_items(@selected_occurrence) != []}
      id="observe-issue-highlights"
      class="flex flex-wrap gap-x-6 gap-y-2 px-4 pt-4"
    >
      <div
        :for={item <- Evidence.highlight_items(@selected_occurrence)}
        class="min-w-0"
      >
        <p class="text-label font-medium text-text-tertiary">
          {item.label}
        </p>
        <p class="text-data font-medium text-text-primary">{item.value}</p>
      </div>
    </div>
    """
  end

  attr :issue, :any, required: true
  attr :occurrences, :list, required: true
  attr :selected_occurrence, :any, required: true

  defp event_actions(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-3 px-4">
      <div class="flex flex-wrap gap-2">
        <.button
          id="observe-issue-older"
          type="button"
          variant="secondary"
          phx-click="select_adjacent_occurrence"
          phx-value-dir="older"
          disabled={
            elem(
              Evidence.adjacent_event_ids(
                @occurrences,
                @selected_occurrence.event_id
              ),
              0
            ) == nil
          }
        >
          Older
        </.button>
        <.button
          id="observe-issue-newer"
          type="button"
          variant="secondary"
          phx-click="select_adjacent_occurrence"
          phx-value-dir="newer"
          disabled={
            elem(
              Evidence.adjacent_event_ids(
                @occurrences,
                @selected_occurrence.event_id
              ),
              1
            ) == nil
          }
        >
          Newer
        </.button>
      </div>
      <div class="flex flex-wrap gap-2">
        <pre id="observe-issue-copy-ai" class="sr-only" phx-no-curly-interpolation><%= Evidence.copy_for_ai(@issue, @selected_occurrence) %></pre>
        <.copy_button
          target="observe-issue-copy-ai"
          label="Copy debugging context"
          size="md"
        />
        <pre id="observe-issue-raw-event" class="sr-only" phx-no-curly-interpolation><%= Evidence.raw_event(@selected_occurrence) %></pre>
        <.copy_button
          target="observe-issue-raw-event"
          label="Copy raw event"
          size="md"
        />
      </div>
    </div>
    """
  end

  attr :selected_occurrence, :any, required: true

  defp user_block(assigns) do
    ~H"""
    <.evidence_block
      :if={@selected_occurrence[:user_id] || @selected_occurrence[:user_email]}
      id="observe-issue-user"
      icon="hero-user"
      title="User"
      collapsed
    >
      <p class="overflow-x-auto rounded-control border border-border-default bg-surface-raised p-3 text-data text-text-primary">
        {@selected_occurrence[:user_id]}
        <span :if={@selected_occurrence[:user_email]} class="text-text-secondary">
          ({@selected_occurrence[:user_email]})
        </span>
      </p>
    </.evidence_block>
    """
  end

  attr :selected_occurrence, :any, required: true

  defp request_block(assigns) do
    ~H"""
    <.evidence_block
      :if={Evidence.request_context(@selected_occurrence)}
      id="observe-issue-request"
      icon="hero-globe-alt"
      title="Request"
    >
      <% request = Evidence.request_context(@selected_occurrence) %>
      <div class="overflow-x-auto rounded-control border border-border-default bg-surface-raised p-3 text-data text-text-primary">
        <p>
          <span class="font-semibold">{request["method"] || request[:method] || "GET"}</span>
          {request["path"] || request[:path] || request["url"] || request[:url]}
        </p>
        <p :if={request["host"] || request[:host]} class="mt-1 text-text-secondary">
          {request["host"] || request[:host]}
        </p>
      </div>
      <.definition_list :if={Evidence.request_detail_items(request) != []}>
        <:row
          :for={item <- Evidence.request_detail_items(request)}
          label={item.label}
        >
          {item.value}
        </:row>
      </.definition_list>
    </.evidence_block>
    """
  end

  attr :selected_occurrence, :any, required: true
  attr :stack_order, :atom, required: true
  attr :stack_view, :atom, required: true
  attr :stack_in_app_only, :boolean, required: true

  defp stacktrace_block(assigns) do
    ~H"""
    <.evidence_block
      :if={is_list(@selected_occurrence[:frames])}
      id="observe-issue-stacktrace"
      icon="hero-queue-list"
      title="Stack trace"
    >
      <div class="mb-3 flex flex-wrap items-center gap-2">
        <div
          id="observe-stack-order"
          class="inline-flex overflow-hidden rounded-control border border-border-control"
          role="group"
          aria-label="Stack order"
        >
          <button
            id="observe-stack-oldest"
            type="button"
            phx-click="set_stack_order"
            phx-value-order="oldest_first"
            aria-pressed={@stack_order == :oldest_first}
            class={[
              stack_segment_class(@stack_order == :oldest_first),
              "border-r border-border-default"
            ]}
          >
            Exception first
          </button>
          <button
            id="observe-stack-newest"
            type="button"
            phx-click="set_stack_order"
            phx-value-order="newest_first"
            aria-pressed={@stack_order == :newest_first}
            class={stack_segment_class(@stack_order == :newest_first)}
          >
            Callers first
          </button>
        </div>
        <div
          id="observe-stack-view"
          class="inline-flex overflow-hidden rounded-control border border-border-control"
          role="group"
          aria-label="Stack view"
        >
          <button
            id="observe-stack-full"
            type="button"
            phx-click="set_stack_view"
            phx-value-view="full"
            aria-pressed={@stack_view == :full}
            class={[
              stack_segment_class(@stack_view == :full),
              "border-r border-border-default"
            ]}
          >
            Source
          </button>
          <button
            id="observe-stack-raw"
            type="button"
            phx-click="set_stack_view"
            phx-value-view="raw"
            aria-pressed={@stack_view == :raw}
            class={stack_segment_class(@stack_view == :raw)}
          >
            Raw
          </button>
        </div>
        <button
          id="observe-stack-in-app"
          type="button"
          phx-click="toggle_in_app_only"
          aria-pressed={@stack_in_app_only}
          class={[
            "inline-flex overflow-hidden rounded-control border border-border-control",
            stack_segment_class(@stack_in_app_only)
          ]}
        >
          In-app only
        </button>
      </div>
      <p id="observe-stack-status" class="mb-2 text-data text-text-secondary">
        {Evidence.stack_summary(@selected_occurrence.frames,
          order: @stack_order,
          in_app_only: @stack_in_app_only,
          view: @stack_view
        )}
      </p>
      <pre
        :if={@stack_view == :raw}
        id="observe-issue-stack-raw"
        phx-no-curly-interpolation
        class="overflow-x-auto rounded-control border border-interactive-ink bg-interactive-ink p-3 font-mono text-data text-interactive-wash"
      ><%= Evidence.raw_stack(@selected_occurrence.frames, order: @stack_order, in_app_only: @stack_in_app_only, type: @selected_occurrence.exception_type, value: @selected_occurrence.exception_value) %></pre>
      <.stack_frames
        :if={@stack_view == :full}
        frames={
          Evidence.visible_frames(@selected_occurrence.frames,
            order: @stack_order,
            in_app_only: @stack_in_app_only
          )
        }
      />
    </.evidence_block>
    """
  end

  attr :selected_occurrence, :any, required: true

  defp causes_block(assigns) do
    ~H"""
    <.evidence_block
      :if={is_list(@selected_occurrence[:causes]) && @selected_occurrence.causes != []}
      id="observe-issue-causes"
      icon="hero-arrow-uturn-left"
      title="Caused by"
      collapsed
    >
      <div :for={cause <- @selected_occurrence.causes} class="space-y-3">
        <p class="text-pretty text-body font-medium text-text-primary">
          {cause[:type]}<span :if={cause[:value]}>: {cause[:value]}</span>
        </p>
        <.stack_frames
          :if={Evidence.unique_cause_frames(cause, @selected_occurrence.frames) != []}
          frames={Evidence.unique_cause_frames(cause, @selected_occurrence.frames)}
        />
      </div>
    </.evidence_block>
    """
  end

  attr :issue, :any, required: true
  attr :selected_occurrence, :any, required: true

  defp context_block(assigns) do
    ~H"""
    <.evidence_block
      :if={Evidence.extra_context(@selected_occurrence, @issue)}
      id="observe-issue-context-block"
      icon="hero-code-bracket"
      title="Context"
      collapsed
    >
      <pre
        phx-no-curly-interpolation
        id="observe-issue-context"
        class="overflow-x-auto rounded-control border border-border-default bg-surface-raised p-3 text-data text-text-primary"
      ><%= context_json(Evidence.extra_context(@selected_occurrence, @issue)) %></pre>
    </.evidence_block>
    """
  end

  attr :selected_occurrence, :any, required: true

  defp breadcrumbs_block(assigns) do
    ~H"""
    <.evidence_block
      :if={
        Evidence.before_crumbs(@selected_occurrence) != [] ||
          Evidence.after_crumbs(@selected_occurrence) != []
      }
      id="observe-issue-breadcrumbs"
      icon="hero-clock"
      title="Timeline"
      collapsed
    >
      <ol class="space-y-0 overflow-x-auto rounded-control border border-border-default bg-surface-raised p-3">
        <li
          :for={crumb <- Evidence.before_crumbs(@selected_occurrence)}
          class="relative border-l border-border-default pb-3 pl-4 last:pb-0"
        >
          <span
            aria-hidden="true"
            class="absolute -left-[4.5px] top-1.5 size-2 rounded-dot border border-border-default bg-surface-raised"
          />
          <.breadcrumb_line
            crumb={crumb}
            occurred_at={@selected_occurrence.occurred_at}
          />
        </li>
        <li
          :if={Evidence.after_crumbs(@selected_occurrence) != []}
          id="observe-issue-error-divider"
          class="relative border-l border-border-default py-2 pl-4 text-label font-medium text-text-primary"
        >
          <span
            aria-hidden="true"
            class="absolute -left-[4.5px] top-3 size-2 rounded-dot bg-status-error"
          /> Error occurred
        </li>
        <li
          :for={crumb <- Evidence.after_crumbs(@selected_occurrence)}
          class="relative border-l border-border-default pb-3 pl-4 last:pb-0"
        >
          <span
            aria-hidden="true"
            class="absolute -left-[4.5px] top-1.5 size-2 rounded-dot border border-border-default bg-surface-raised"
          />
          <.breadcrumb_line
            crumb={crumb}
            occurred_at={@selected_occurrence.occurred_at}
          />
        </li>
      </ol>
    </.evidence_block>
    """
  end

  attr :issue, :any, required: true
  attr :org_token, :string, required: true
  attr :project, :any, required: true
  attr :selected_occurrence, :any, required: true

  defp tags_block(assigns) do
    ~H"""
    <.evidence_block
      :if={is_map(@selected_occurrence[:tags]) && map_size(@selected_occurrence.tags) > 0}
      id="observe-issue-tags"
      icon="hero-tag"
      title="Tags"
      collapsed
    >
      <div class="flex flex-wrap gap-2">
        <.link
          :for={{key, value} <- @selected_occurrence.tags}
          :if={tag_filter_path(@org_token, @project, @issue.source_id, key, value)}
          id={"observe-issue-tag-#{key}"}
          navigate={tag_filter_path(@org_token, @project, @issue.source_id, key, value)}
        >
          <.status_badge tone="neutral" label={"#{key}: #{value}"} />
        </.link>
        <.status_badge
          :for={{key, value} <- @selected_occurrence.tags}
          :if={is_nil(tag_filter_path(@org_token, @project, @issue.source_id, key, value))}
          tone="neutral"
          label={"#{key}: #{value}"}
        />
      </div>
    </.evidence_block>
    """
  end

  attr :occurrences, :list, required: true
  attr :occurrence_columns, :list, required: true
  attr :selected_occurrence, :any, required: true

  defp occurrences_block(assigns) do
    ~H"""
    <.evidence_block
      :if={length(@occurrences) > 1}
      id="observe-issue-occurrences-block"
      icon="hero-rectangle-stack"
      title="Recent occurrences"
      collapsed
    >
      <div
        id="observe-issue-occurrence-mobile"
        class="divide-y divide-border-default border-y border-border-default sm:hidden"
      >
        <article :for={occurrence <- @occurrences} class="space-y-2 px-3 py-3">
          <button
            type="button"
            id={"select-occurrence-mobile-#{occurrence.event_id}"}
            phx-click="select_occurrence"
            phx-value-event-id={occurrence.event_id}
            aria-pressed={to_string(selected?(occurrence, @selected_occurrence))}
            class={[
              "flex min-h-target-min w-full items-center justify-between gap-3 text-left text-data",
              selected?(occurrence, @selected_occurrence) &&
                "font-semibold text-interactive-strong"
            ]}
          >
            <span>Received</span>
            <time class="tabular-nums" title={format_utc(occurrence.received_at)}>
              {format_utc(occurrence.received_at)}
            </time>
          </button>
          <dl class="grid grid-cols-2 gap-x-4 gap-y-2 text-data">
            <div :if={:user in @occurrence_columns}>
              <dt class="text-text-tertiary">User</dt>
              <dd class="mt-0.5 break-words text-text-primary">
                {occurrence.user_id || occurrence.user_email || "-"}
              </dd>
            </div>
            <div :if={:release in @occurrence_columns}>
              <dt class="text-text-tertiary">Release</dt>
              <dd class="mt-0.5 break-words text-text-primary">
                {occurrence.release || "-"}
              </dd>
            </div>
            <div :if={:sdk in @occurrence_columns} class="col-span-2">
              <dt class="text-text-tertiary">SDK</dt>
              <dd class="mt-0.5 break-words text-text-primary">
                {occurrence.sdk_name} {occurrence.sdk_version}
              </dd>
            </div>
          </dl>
        </article>
      </div>
      <div
        id="observe-issue-occurrence-table"
        class="hidden overflow-x-auto sm:block"
      >
        <.table id="observe-issue-occurrences" rows={@occurrences}>
          <:col :let={occurrence} label="Received">
            <button
              type="button"
              id={"select-occurrence-#{occurrence.event_id}"}
              phx-click="select_occurrence"
              phx-value-event-id={occurrence.event_id}
              aria-pressed={
                if(selected?(occurrence, @selected_occurrence),
                  do: "true",
                  else: "false"
                )
              }
              class={[
                "inline-flex min-h-target-min items-center hover:underline",
                selected?(occurrence, @selected_occurrence) &&
                  "font-semibold text-interactive-strong"
              ]}
            >
              <time class="tabular-nums" title={format_utc(occurrence.received_at)}>
                {format_utc(occurrence.received_at)}
              </time>
            </button>
          </:col>
          <:col :let={occurrence} :if={:user in @occurrence_columns} label="User">
            {occurrence.user_id || occurrence.user_email || "-"}
          </:col>
          <:col
            :let={occurrence}
            :if={:release in @occurrence_columns}
            label="Release"
          >
            {occurrence.release || "-"}
          </:col>
          <:col :let={occurrence} :if={:sdk in @occurrence_columns} label="SDK">
            {occurrence.sdk_name} {occurrence.sdk_version}
          </:col>
        </.table>
      </div>
    </.evidence_block>
    """
  end

  attr :selected_occurrence, :any, required: true
  attr :full_payload, :any, default: nil
  attr :full_payload_error, :any, default: nil
  attr :full_payload_loading?, :boolean, required: true

  defp full_payload_block(assigns) do
    ~H"""
    <.evidence_block
      :if={
        @selected_occurrence[:payload_s3_key] || @full_payload || @full_payload_error ||
          @full_payload_loading?
      }
      id="observe-issue-full-payload-block"
      title="Full payload"
      collapsed
    >
      <.button
        :if={
          @selected_occurrence[:payload_s3_key] &&
            is_nil(@full_payload) &&
            is_nil(@full_payload_error) &&
            not @full_payload_loading?
        }
        id="fetch-full-payload"
        type="button"
        variant="secondary"
        phx-click="fetch_full_payload"
      >
        Load full payload
      </.button>
      <p
        :if={@full_payload_loading?}
        id="observe-issue-full-payload-loading"
        role="status"
        aria-live="polite"
        class="text-body text-text-secondary"
      >
        Loading full payload...
      </p>
      <p
        :if={@full_payload_error}
        id="observe-issue-full-payload-error"
        class="text-data text-status-error-ink"
      >
        {full_payload_error_message(@full_payload_error)}
      </p>
      <.button
        :if={@full_payload_error && not @full_payload_loading?}
        id="fetch-full-payload"
        type="button"
        variant="secondary"
        phx-click="fetch_full_payload"
      >
        Retry loading full payload
      </.button>
      <pre
        :if={@full_payload}
        phx-no-curly-interpolation
        id="observe-issue-full-payload"
        class="overflow-x-auto rounded-control bg-surface-raised p-3 text-data text-text-primary"
      ><%= context_json(@full_payload) %></pre>
    </.evidence_block>
    """
  end

  attr :issue, :any, required: true
  attr :selected_occurrence, :any, required: true

  defp no_context_block(assigns) do
    ~H"""
    <div :if={is_nil(@selected_occurrence)} class="p-4">
      <pre
        :if={@issue.context_summary && map_size(@issue.context_summary) > 0}
        phx-no-curly-interpolation
        id="observe-issue-context"
        class="overflow-x-auto rounded-control bg-surface-sunken p-3 text-data text-text-primary"
      ><%= context_json(@issue.context_summary) %></pre>
      <p
        id="observe-issue-no-context"
        class="mt-3 text-pretty text-data text-text-tertiary"
      >
        No per-event evidence has been captured for this issue yet.
      </p>
    </div>
    """
  end

  attr :merged_children, :list, required: true
  attr :merged_children_count, :integer, required: true
  attr :merged_children_more?, :boolean, required: true
  attr :org_token, :string, required: true
  attr :project, :any, required: true

  defp merged_children_block(assigns) do
    ~H"""
    <.evidence_block
      :if={@merged_children != []}
      id="observe-issue-merged-children"
      icon="hero-arrows-pointing-in"
      title={"Merged issues (#{@merged_children_count})"}
      collapsed
    >
      <div class="overflow-x-auto">
        <.table id="observe-issue-merged-children-table" rows={@merged_children}>
          <:col :let={child} label="Issue">
            <.link
              navigate={
                ~p"/dashboard/orgs/#{@org_token}/projects/#{@project.public_token}/observe/issues/#{child.id}"
              }
              class="font-medium text-text-primary hover:underline"
            >
              {child.title}
            </.link>
            <p class="mt-0.5 text-data text-text-tertiary">
              {child.culprit || "No cause identified yet."}
            </p>
          </:col>
          <:col :let={child} label="Events">{child.event_count}</:col>
          <:col :let={child} label="Last seen">
            <time title={format_utc(child.last_seen_at)}>
              {format_utc(child.last_seen_at)}
            </time>
          </:col>
        </.table>
      </div>
      <.button
        :if={@merged_children_more?}
        id="observe-issue-merged-children-load-more"
        type="button"
        variant="secondary"
        class="mt-4"
        phx-click="load_more_merged_children"
      >
        Load more merged issues
      </.button>
    </.evidence_block>
    """
  end

  # Evidence topics read as article sections inside one data panel. Hairlines
  # and spacing carry hierarchy; nested bordered cards do not.
  #
  # Only the stack trace and the request stay open. Everything else is
  # supporting evidence a reader opts into, so it renders as a closed
  # disclosure and the screen keeps one answer at the top.
  attr :id, :string, default: nil
  attr :icon, :string, default: nil
  attr :title, :string, required: true
  attr :collapsed, :boolean, default: false
  slot :inner_block, required: true

  def evidence_block(%{collapsed: true} = assigns) do
    ~H"""
    <details id={@id} class="border-t border-border-default px-4 py-3 first:border-t-0">
      <summary class="flex min-h-target-min cursor-pointer items-center gap-2 py-1 text-label font-medium text-text-secondary focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus">
        <.icon :if={@icon} name={@icon} class="size-4 shrink-0 text-text-tertiary" />
        {@title}
      </summary>
      <div class="mt-3">{render_slot(@inner_block)}</div>
    </details>
    """
  end

  def evidence_block(assigns) do
    ~H"""
    <article id={@id} class="border-t border-border-default px-4 py-5 first:border-t-0">
      <h3 class="flex items-center gap-2 text-body font-semibold text-text-primary">
        <.icon :if={@icon} name={@icon} class="size-4 shrink-0 text-text-tertiary" />
        {@title}
      </h3>
      <div class="mt-3">{render_slot(@inner_block)}</div>
    </article>
    """
  end

  defp selected?(occurrence, selected),
    do: selected && occurrence.event_id == selected.event_id

  defp context_json(context) do
    sanitized = EvidenceScrubber.scrub(context)

    encoded =
      case Jason.encode(sanitized, pretty: true) do
        {:ok, json} -> json
        {:error, _} -> inspect(sanitized)
      end

    String.slice(encoded, 0, @max_evidence_bytes)
  end

  defp full_payload_error_message(:not_found), do: "The full payload is no longer available."

  defp full_payload_error_message(:timeout),
    do: "Fetching the full payload timed out. Try again."

  defp full_payload_error_message(:unparseable),
    do: "The stored full payload could not be read."

  defp full_payload_error_message(_other),
    do: "Could not fetch the full payload right now."

  defp status_tone(:open), do: "neutral"
  defp status_tone(:resolved), do: "success"
  defp status_tone(:ignored), do: "neutral"

  defp count_label(1, noun), do: "1 " <> noun
  defp count_label(count, noun), do: "#{count} #{noun}s"

  # The issue screen's one answer, built only from values already loaded.
  # Users affected joins the clause only when the number was actually
  # captured; "0 users" would read as a measurement rather than as a gap.
  defp issue_impact_answer(event_count, first_seen_at, users_affected) do
    [
      count_label(event_count, "event"),
      users_clause(users_affected),
      "first seen #{Evidence.relative_time(first_seen_at)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp users_clause(0), do: nil
  defp users_clause(count), do: count_label(count, "user") <> " affected"

  defp release_label(%{release_last_seen: release}, _latest, _resolved)
       when is_binary(release) and release != "",
       do: release

  defp release_label(%{release_first_seen: release}, _latest, _resolved)
       when is_binary(release) and release != "",
       do: release

  defp release_label(%{resolved_in_release_id: release_id}, _latest, %Release{version: version})
       when not is_nil(release_id) and is_binary(version),
       do: version

  defp release_label(%{resolved_in_release_id: nil}, %Release{version: version}, _resolved)
       when is_binary(version),
       do: version

  defp release_label(_issue, _latest, _resolved), do: "Not recorded"

  defp stack_segment_class(true),
    do:
      "inline-flex min-h-target-min items-center bg-interactive-tint px-3 text-label font-semibold text-text-primary"

  defp stack_segment_class(false),
    do:
      "inline-flex min-h-target-min items-center bg-surface-raised px-3 text-label text-text-secondary hover:bg-interactive-tint"

  defp tag_filter_path(_org_token, _project, nil, _key, _value), do: nil

  defp tag_filter_path(org_token, project, source_id, key, value) do
    ~p"/dashboard/orgs/#{org_token}/projects/#{project.public_token}/observe/#{source_id}?#{%{tag: key <> ":" <> value}}"
  end

  @doc "Tabs the Evidence tab bar shows, with live comment/report counts."
  @spec issue_tabs(non_neg_integer(), non_neg_integer()) :: [map()]
  def issue_tabs(comment_count, report_count) do
    [
      %{id: "event", label: "Evidence", panel_id: "observe-issue-event"},
      %{
        id: "comments",
        label: "Comments (#{comment_count})",
        panel_id: "observe-issue-comments"
      },
      %{
        id: "reports",
        label: "User reports (#{report_count})",
        panel_id: "observe-issue-reports"
      }
    ]
  end
end
