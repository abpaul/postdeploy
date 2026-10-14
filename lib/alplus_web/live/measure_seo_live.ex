defmodule AlplusWeb.MeasureSeoLive do
  @moduledoc "Private, feature-gated SEO visibility view within Measure."

  use AlplusWeb, :live_view

  import AlplusWeb.ConsoleComponents
  import AlplusWeb.DashboardComponents

  alias Alplus.Seo.Feature

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  @tabs [
    %{id: "overview", label: "Overview"},
    %{id: "keywords", label: "Keywords"},
    %{id: "pages", label: "Pages"},
    %{id: "competitors", label: "Competitors"}
  ]

  @impl true
  def mount(%{"org_token" => org_token, "project_token" => project_token}, _session, socket) do
    with {:ok, socket} <-
           AlplusWeb.OrgContext.mount(org_token, socket, page_title: "SEO", active: :measure),
         true <- Feature.enabled?(socket.assigns.scope) do
      project = AlplusWeb.OrgContext.project_for_token!(socket, project_token)
      scope = %{socket.assigns.scope | project_id: project.id}

      {:ok,
       assign(socket,
         projects: [project],
         project: project,
         profiles: Alplus.Seo.list_profiles!(project.id, actor: scope),
         seo_tabs: @tabs,
         agent_state: AlplusWeb.AgentConnection.state(scope),
         selected_tab: "overview"
       )}
    else
      false -> raise AlplusWeb.NotFoundError
    end
  end

  @impl true
  def handle_event("select_seo_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :selected_tab, valid_tab(tab))}
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
    >
      <.console_page id="measure-seo-page">
        <:title>{page_title(@profiles)}</:title>

        <.tabs
          :if={@profiles != []}
          id="measure-seo-tabs"
          tabs={@seo_tabs}
          active={@selected_tab}
          on_change="select_seo_tab"
          aria_label="SEO sections"
          class="border-b border-border-default"
        />

        <.first_run_card
          :if={@profiles == []}
          id="measure-seo-empty"
          title="Add an SEO profile"
          description="Choose a Measure site, a Google market, and up to three competitors. The first refresh starts after setup."
          state={@agent_state}
          task={"Add an SEO profile for a Measure site in project #{@project.id}. Set its Google country and language, then add up to three competitors."}
          action_href={~p"/dashboard/orgs/#{@org_token}/projects/#{@project.public_token}/connect"}
        />

        <.section_card :if={@profiles != []} id="measure-seo-data" title={tab_title(@selected_tab)}>
          <%= case latest_snapshot(@profiles, @scope) do %>
            <% nil -> %>
              <p class="text-body text-text-secondary">
                SEO data will appear after the first refresh. It reports Google organic visibility and estimated organic traffic.
              </p>
            <% snapshot -> %>
              <.seo_snapshot tab={@selected_tab} snapshot={snapshot} />
          <% end %>
        </.section_card>
      </.console_page>
    </.dashboard_shell>
    """
  end

  defp page_title([]), do: "Add an SEO profile"
  defp page_title(_profiles), do: "Google organic visibility"

  defp latest_snapshot([profile | _], scope) do
    case Alplus.Seo.latest_snapshot(profile.id, actor: scope) do
      {:ok, snapshot} -> snapshot
      _ -> nil
    end
  end

  defp latest_snapshot([], _scope), do: nil

  attr :tab, :string, required: true
  attr :snapshot, :map, required: true

  defp seo_snapshot(assigns) do
    ~H"""
    <div :if={@tab == "overview"} class="space-y-2">
      <p class="text-heading-03 text-text-primary">
        {Map.get(@snapshot.overview, "count", 0)} organic rankings
      </p>
      <p class="text-body text-text-secondary">
        Estimated organic traffic: {Map.get(@snapshot.overview, "etv", 0)} per month.
      </p>
      <p class="text-caption text-text-tertiary">
        Updated {Calendar.strftime(@snapshot.captured_at, "%Y-%m-%d %H:%M UTC")}
      </p>
    </div>
    <div :if={@tab == "keywords"} class="space-y-2">
      <p class="text-body text-text-secondary">Top {length(@snapshot.keywords)} organic keywords.</p>
      <p :for={row <- Enum.take(@snapshot.keywords, 10)} class="text-body text-text-primary">
        {Map.get(row, "keyword_data", %{}) |> Map.get("keyword", "Keyword unavailable")}
      </p>
    </div>
    <div :if={@tab == "pages"} class="space-y-2">
      <p class="text-body text-text-secondary">
        Top {length(@snapshot.pages)} pages by organic visibility.
      </p>
      <p :for={row <- Enum.take(@snapshot.pages, 10)} class="text-body text-text-primary">
        {Map.get(row, "url", "Page unavailable")}
      </p>
    </div>
    <div :if={@tab == "competitors"} class="space-y-2">
      <p :for={competitor <- @snapshot.competitors} class="text-body text-text-primary">
        {Map.get(competitor, "target", Map.get(competitor, :target, "Competitor"))}
      </p>
    </div>
    """
  end

  defp valid_tab(tab) when tab in ~w(overview keywords pages competitors), do: tab
  defp valid_tab(_tab), do: "overview"

  defp tab_title("overview"), do: "SEO overview"
  defp tab_title("keywords"), do: "Ranked keywords"
  defp tab_title("pages"), do: "Ranked pages"
  defp tab_title("competitors"), do: "Competitor comparison"
end
