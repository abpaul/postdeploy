defmodule AlplusWeb.MeasureLive do
  @moduledoc """
  Project-scoped Measure portfolio for one project.

  This surface is intentionally read-only. Source lifecycle and installation
  operations live behind the connected agent runway; this page is one hero
  chart of the project's pageviews, three readings beside it, and the list of
  sites under it.

  The whole screen is `Alplus.Measure.Dashboard.portfolio/4`: one query pair
  for every site, current period and the immediately preceding equal period.
  Inside proven coverage a quiet bucket is a measured zero and is drawn on the
  baseline; a bucket nobody could measure stays `nil` and is drawn as nothing.
  """

  use AlplusWeb, :live_view

  import AlplusWeb.ConsoleComponents
  import AlplusWeb.DashboardComponents
  import AlplusWeb.MeasureActivityComponents
  import AlplusWeb.Format, only: [window_words: 1]

  alias Alplus.Measure.Dashboard

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  # Exactly the three ranges the window control offers. A deep link to a range
  # with no button reaches a display grid nothing on this screen describes, so
  # an unknown window falls back to the default rather than being honoured.
  @windows ~w(24h 7d 30d)

  @impl true
  def mount(%{"org_token" => org_token, "project_token" => project_token}, _session, socket) do
    with {:ok, socket} <-
           AlplusWeb.OrgContext.mount(org_token, socket, page_title: "Traffic", active: :measure) do
      project = AlplusWeb.OrgContext.project_for_token!(socket, project_token)

      {:ok,
       assign(socket,
         projects: [project],
         project: project,
         window: "24h",
         sources: [],
         portfolio: empty_portfolio(),
         agent_state: nil,
         loading?: true,
         load_failed?: false
       )}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:window, valid_window(params["window"]))
      |> load_portfolio()
      |> maybe_activate_measure()

    {:noreply, socket}
  end

  @impl true
  def handle_event("retry_measure", _params, socket) do
    {:noreply, load_portfolio(socket)}
  end

  def handle_event("pick_window", %{"window" => window}, socket) do
    {:noreply, push_patch(socket, to: measure_path(socket.assigns, valid_window(window)))}
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
      active={:measure}
      nav_project={@project}
      nav_projects={@nav_projects}
      project_scoped={false}
      page_heading?={false}
      window={@window}
    >
      <.console_page id="measure-page">
        <:title>{traffic_answer(@sources, @portfolio, @window, @loading?, @load_failed?)}</:title>
        <.error_boundary :if={@load_failed?} id="measure-error" retry="retry_measure">
          Could not load traffic. Nothing is estimated while the read is failing.
        </.error_boundary>

        <div :if={@loading?} id="measure-loading" role="status" aria-live="polite" class="space-y-4">
          <span class="sr-only">Loading your traffic.</span>
          <.skeleton rows={4} />
        </div>

        <div :if={not @loading? and not @load_failed?} class="grid gap-6">
          <.traffic_overview
            portfolio={@portfolio}
            window={@window}
            placeholder={@sources == []}
            context={"#{@project.name}, all sites"}
          >
            <:rail :if={@sources != []}>
              <.measure_site_list
                sources={@sources}
                portfolio={@portfolio}
                org_token={@org_token}
                project={@project}
              />
            </:rail>
          </.traffic_overview>

          <%!-- A project with no connected site keeps the chart it is about
                to get, and one card that says how to start it. --%>
          <.first_run_card
            :if={@sources == []}
            id="measure-sites-empty"
            title="Connect a site"
            description="Pageviews appear here after the tracking snippet starts sending."
            state={@agent_state}
            task={"Check whether any site in project #{@project.id} is sending traffic, and report what is missing."}
            action_href={~p"/dashboard/orgs/#{@org_token}/projects/#{@project.public_token}/connect"}
          />
        </div>
      </.console_page>
    </.dashboard_shell>
    """
  end

  # The screen's title is its answer: how much traffic arrived in the range,
  # counted from what was measured, and never "Unavailable" for a number the
  # chart already draws.
  defp traffic_answer(_sources, _portfolio, _window, true, _failed?), do: "Traffic"
  defp traffic_answer(_sources, _portfolio, _window, _loading?, true), do: "Traffic"
  defp traffic_answer([], _portfolio, _window, _loading?, _failed?), do: "Connect a site"

  defp traffic_answer(_sources, portfolio, window, _loading?, _failed?) do
    reading = get_in(portfolio, [:totals, :pageviews]) || %{}
    period = "in the last #{window_words(window)}"

    cond do
      Map.get(portfolio, :unavailable?, false) ->
        "Traffic could not be loaded"

      Map.get(reading, :coverage) == :partial and is_number(Map.get(reading, :known_value)) ->
        "#{thousands(reading.known_value)} #{pageview_word(reading.known_value)} #{period}"

      is_number(Map.get(reading, :value)) and reading.value > 0 ->
        "#{thousands(reading.value)} #{pageview_word(reading.value)} #{period}"

      true ->
        "No traffic #{period} yet"
    end
  end

  defp pageview_word(1), do: "pageview"
  defp pageview_word(_count), do: "pageviews"

  defp thousands(value), do: AlplusWeb.Marketing.PackagePresenter.thousands(value)

  defp measure_path(assigns, window) do
    ~p"/dashboard/orgs/#{assigns.org_token}/projects/#{assigns.project.public_token}/measure?#{%{"window" => window}}"
  end

  defp load_portfolio(socket) do
    project = socket.assigns.project
    window = socket.assigns.window
    project_scope = %{socket.assigns.scope | project_id: project.id}

    try do
      sources =
        Alplus.Sources.list_sources_for_project!(project.id, actor: project_scope)
        |> Enum.filter(&(&1.type == :measure))
        |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})

      portfolio =
        if sources == [],
          do: empty_portfolio(),
          else: Dashboard.portfolio(sources, window, project_scope)

      assign(socket,
        sources: sources,
        portfolio: portfolio,
        # Only the first-run card reads this, so it is only paid for when the
        # screen has nothing else to draw.
        agent_state:
          if(sources == [], do: AlplusWeb.AgentConnection.state(project_scope), else: nil),
        loading?: false,
        load_failed?: false
      )
    rescue
      error in [DBConnection.ConnectionError, Postgrex.Error] ->
        require Logger
        Logger.error("measure portfolio load failed: #{Exception.message(error)}")
        assign(socket, loading?: false, load_failed?: true)
    end
  end

  # Persist the project-level activation milestone once traffic has arrived.
  # The timestamp prevents reloads, reconnects, and later window changes from
  # repeating the transition.
  defp maybe_activate_measure(socket) do
    project = socket.assigns.project

    pageviews =
      socket.assigns.portfolio
      |> Map.get(:totals, %{})
      |> Map.get(:pageviews, %{})
      |> Map.get(:value)

    traffic_evidence? =
      Map.get(socket.assigns.portfolio, :evidence?, false) or
        (is_number(pageviews) and pageviews > 0)

    if is_nil(project.measure_activated_at) and not socket.assigns.load_failed? and
         traffic_evidence? do
      case Alplus.Projects.activate_measure(project, actor: socket.assigns.scope) do
        {:ok, activated_project} ->
          socket
          |> assign(:project, activated_project)
          |> put_flash(:info, "Traffic is arriving. Measure is now live for this project.")

        {:error, _reason} ->
          socket
      end
    else
      socket
    end
  end

  # A project with nothing connected still has a shape: no readings, no
  # buckets, and no claim that anything failed.
  defp empty_portfolio do
    %{
      totals: %{
        pageviews: %{value: nil, previous: nil, change: nil},
        visits: %{value: nil, previous: nil, change: nil},
        active_sites: 0,
        connected_sites: 0
      },
      trend: [],
      sites: %{},
      unavailable?: false,
      partial?: false
    }
  end

  defp valid_window(window) when window in @windows, do: window
  defp valid_window(_window), do: "24h"
end
