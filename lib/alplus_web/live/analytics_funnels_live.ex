defmodule AlplusWeb.AnalyticsFunnelsLive do
  @moduledoc """
  The saved funnels on one project, with the selected one drawn in full.

  This screen is read-only, like the rest of the console: funnels are
  created, edited, and deleted through MCP (PRODUCT.md). A project with no
  saved funnel gets the prompt to hand its agent, not a form.
  """

  use AlplusWeb, :live_view

  import AlplusWeb.AnalyticsComponents
  import AlplusWeb.ConsoleComponents
  import AlplusWeb.DashboardComponents

  alias Alplus.Analytics.Queries
  alias AlplusWeb.Analytics.Context

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(params, _session, socket) do
    with {:ok, socket} <- Context.mount(params, socket, "Funnels") do
      {:ok, assign(socket, funnels: [], selected: nil, results: [], agent_state: nil)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> Context.put_window(params)
      |> Context.put_source(params)
      |> assign(:selected_id, params["funnel"])
      |> load()

    {:noreply, socket}
  end

  @impl true
  def handle_event("retry_analytics", _params, socket), do: {:noreply, load(socket)}

  def handle_event("pick_window", %{"window" => window}, socket) do
    {:noreply, patch(socket, %{"window" => Queries.valid_window(window)})}
  end

  def handle_event("pick_app", %{"source" => source}, socket) do
    {:noreply, patch(socket, %{"source" => source})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_shell
      agent_connected?={@agent_connected?}
      flash={@flash}
      org={@org}
      organizations={@organizations}
      scope={@scope}
      current_user={@current_user}
      active={:analytics}
      nav_project={@project}
      nav_projects={@nav_projects}
      page_heading?={false}
      window={@funnels != [] && @window}
      windows={Queries.windows()}
    >
      <.console_page id="analytics-funnels-page">
        <:title>{if @selected, do: @selected.name, else: "Funnels"}</:title>
        <:intro :if={@selected}>
          Conversion is measured from each person's first {List.first(@selected.steps)} event, inside {hours_words(
            @selected.window_hours
          )}.
        </:intro>

        <.error_boundary :if={@load_failed?} id="analytics-funnels-error" retry="retry_analytics">
          Could not load funnels.
        </.error_boundary>

        <div :if={@loading?} role="status" aria-live="polite">
          <span class="sr-only">Loading funnels.</span>
          <.skeleton rows={4} />
        </div>

        <.first_run_card
          :if={not @loading? and not @load_failed? and @funnels == []}
          id="analytics-funnels-empty"
          title="Save your first funnel"
          description="A funnel names two to eight events in order and reports how many people reach each one."
          state={@agent_state}
          task="Create a funnel named Onboarding with the steps first_open, onboarding_completed and meal_logged."
          action_href={
            ~p"/dashboard/orgs/#{@org.public_token}/projects/#{@project.public_token}/connect"
          }
        />

        <div :if={not @loading? and not @load_failed? and @funnels != []} class="grid gap-6">
          <.app_select sources={@analytics_sources} source_id={@source_id} />

          <nav :if={length(@funnels) > 1} aria-label="Saved funnels" class="flex flex-wrap gap-2">
            <.link
              :for={funnel <- @funnels}
              patch={patch_path(assigns, funnel)}
              aria-current={@selected && funnel.id == @selected.id && "page"}
              class={[
                "h-control-sm rounded-control border px-3 py-1.5 text-label",
                @selected && funnel.id == @selected.id &&
                  "border-border-default bg-surface-raised text-text-primary",
                (!@selected or funnel.id != @selected.id) &&
                  "border-transparent text-text-secondary hover:text-text-primary"
              ]}
            >
              {funnel.name}
            </.link>
          </nav>

          <.data_panel
            :for={{entry, index} <- Enum.with_index(@results)}
            id={"analytics-funnel-result-#{index}"}
            title={result_title(entry, @selected)}
            padded
          >
            <.funnel_steps id={"analytics-funnel-steps-#{index}"} entry={entry} />
            <:footer>
              {count(entry.entered)} entered, {count(entry.converted)} reached the last step, {percent(
                entry.overall_rate
              )} overall.
            </:footer>
          </.data_panel>

          <p
            :if={truncated?(@results, @selected)}
            class="text-caption text-text-secondary"
          >
            Showing the {Alplus.Analytics.Limits.breakdown_max_values()} {@selected.breakdown_property} values
            with the most people entering. Others are not drawn.
          </p>

          <.empty_state
            :if={@results == []}
            id="analytics-funnel-no-data"
            title="Nobody entered this funnel in this range"
            description={"No #{List.first(@selected.steps)} event was recorded in the #{window_words(@window)}."}
          />
        </div>
      </.console_page>
    </.dashboard_shell>
    """
  end

  # The funnel query caps its breakdown at the same number of values as every
  # other breakdown. Say so, rather than letting a reader treat a truncated
  # list as the whole population.
  defp truncated?(results, %{breakdown_property: property}) when is_binary(property),
    do: length(results) >= Alplus.Analytics.Limits.breakdown_max_values()

  defp truncated?(_results, _funnel), do: false

  defp result_title(%{breakdown_value: nil}, funnel), do: funnel.name

  defp result_title(%{breakdown_value: value}, funnel),
    do: "#{funnel.name}, #{funnel.breakdown_property} = #{value}"

  defp hours_words(hours) when hours < 48, do: "#{hours} hours"
  defp hours_words(hours), do: "#{div(hours, 24)} days"

  defp patch_path(assigns, funnel) do
    params =
      %{"window" => assigns.window, "funnel" => funnel.id, "source" => assigns.source_id}
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    Context.path(assigns, "/funnels", params)
  end

  defp patch(socket, overrides) do
    params =
      %{
        "window" => socket.assigns.window,
        "source" => socket.assigns.source_id,
        "funnel" => socket.assigns[:selected_id]
      }
      |> Map.merge(overrides)
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    push_patch(socket, to: Context.path(socket.assigns, "/funnels", params))
  end

  defp load(socket) do
    Context.load(socket, fn ->
      scope = socket.assigns.project_scope
      funnels = Alplus.Analytics.list_funnels_for_project!(scope.project_id, actor: scope)
      selected = select(funnels, socket.assigns[:selected_id])

      [
        funnels: funnels,
        selected: selected,
        results: results(scope, socket.assigns.window, selected, Context.read_opts(socket)),
        agent_state: if(funnels == [], do: AlplusWeb.AgentConnection.state(scope))
      ]
    end)
  end

  defp select([], _id), do: nil
  defp select([first | _rest], nil), do: first

  defp select(funnels, id),
    do: Enum.find(funnels, List.first(funnels), &(&1.id == id))

  defp results(_scope, _window, nil, _opts), do: []

  defp results(scope, window, funnel, opts) do
    scope
    |> Queries.funnel(
      Queries.range(window),
      funnel.steps,
      opts ++
        [
          window_hours: funnel.window_hours,
          filters: funnel.filters,
          breakdown: funnel.breakdown_property
        ]
    )
    |> Enum.map(&Queries.with_conversions/1)
  end
end
