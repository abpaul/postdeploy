defmodule AlplusWeb.PublicPageSettingsLive do
  @moduledoc "Analysis-only Public identity and publication evidence."

  use AlplusWeb, :live_view

  import AlplusWeb.ConsoleComponents
  import AlplusWeb.DashboardComponents

  alias Alplus.Changelog
  alias Alplus.PublicPages
  alias Alplus.Status

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"org_token" => org_token, "project_token" => project_token}, _session, socket) do
    with {:ok, socket} <-
           AlplusWeb.OrgContext.mount(org_token, socket,
             page_title: "Public identity",
             active: :public
           ) do
      project =
        if connected?(socket),
          do: AlplusWeb.OrgContext.project_for_token!(socket, project_token),
          else: %{public_token: project_token, id: nil, name: "Project"}

      scope =
        if project.id,
          do: Alplus.Scope.put_project(socket.assigns.scope, project.id),
          else: socket.assigns.scope

      socket =
        socket
        |> assign(
          scope: scope,
          project: project,
          public_page: nil,
          public_aliases: [],
          status_setup?: false,
          changelog_setup?: false,
          agent_state: nil,
          load_state: :loading
        )

      {:ok, if(connected?(socket), do: load_public_page(socket), else: socket)}
    end
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{project: %{id: nil}}} = socket) do
    if connected?(socket) do
      project =
        AlplusWeb.OrgContext.project_for_token!(socket, socket.assigns.project.public_token)

      {:noreply,
       socket
       |> assign(
         project: project,
         scope: Alplus.Scope.put_project(socket.assigns.scope, project.id)
       )
       |> load_public_page()}
    else
      {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("retry_public_page_settings", _params, socket) do
    {:noreply, load_public_page(socket)}
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
      active={:project_settings}
      page_title="Public identity"
      page_heading?={false}
      nav_project={@project}
      nav_projects={@nav_projects}
    >
      <.console_page id="public-page-settings-page">
        <:title>Public identity</:title>
        <div id="public-page-settings" class="flex flex-col gap-4">
          <div :if={@load_state == :loading} id="public-page-settings-loading" aria-busy="true">
            <.skeleton rows={3} />
          </div>

          <.error_boundary
            :if={@load_state == :unavailable}
            id="public-page-settings-unavailable"
            retry="retry_public_page_settings"
          >
            Public identity is unavailable. Customer-facing aliases and cached public
            behavior are unchanged.
          </.error_boundary>

          <.first_run_card
            :if={@load_state == :ready and is_nil(@public_page)}
            id="public-page-settings-empty"
            title="No public name or address yet"
            description="Your status page and changelog share one public name, one address, and one logo. Set them once and both pages use them."
            state={@agent_state}
            task="Set the public name, address, and logo used by this project's status page and changelog, then return the public URL."
            action_href={connect_path(@org_token, @project)}
          />

          <.data_panel
            :if={@load_state == :ready and @public_page}
            id="public-page-settings-panel"
            padded
            class="min-w-0"
          >
            <.definition_list>
              <:row label="Title" face={:prose}>{@public_page.title}</:row>
              <:row label="Address">
                <span class="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1">
                  <code id="public-page-canonical-link" class="min-w-0 break-all font-mono">
                    {public_page_url(@public_page)}
                  </code>
                  <.copy_button target="public-page-canonical-link" />
                  <a
                    :if={@public_page.published_at}
                    href={public_page_url(@public_page)}
                    target="_blank"
                    rel="noopener"
                    class="font-sans text-body font-medium text-interactive-strong hover:underline"
                  >
                    Open
                  </a>
                </span>
              </:row>
              <:row label="Logo" face={:prose}>{@public_page.logo_url || "None"}</:row>
              <:row label="Publication">
                <span class="flex items-center gap-x-3">
                  <.status_badge
                    tone={if(@public_page.published_at, do: "success", else: "neutral")}
                    label={if(@public_page.published_at, do: "Published", else: "Private")}
                  />
                  <span :if={@public_page.published_at} class="text-caption text-text-tertiary">
                    <.timestamp at={@public_page.published_at} class="tabular-nums" />
                  </span>
                </span>
              </:row>
              <:row :if={@public_aliases != []} label="Previous addresses">
                <ul id="public-page-aliases" class="space-y-1">
                  <li :for={alias <- @public_aliases} id={"public-page-alias-#{alias.id}"}>
                    <a
                      href={public_page_url(alias)}
                      target="_blank"
                      rel="noopener"
                      class="break-all font-mono text-data text-interactive-strong underline underline-offset-2"
                    >{public_page_url(alias)}</a>
                  </li>
                </ul>
              </:row>
            </.definition_list>
            <:footer>Your agent changes these. Previous addresses keep working.</:footer>
          </.data_panel>
        </div>
      </.console_page>
    </.dashboard_shell>
    """
  end

  defp load_public_page(socket) do
    scope = socket.assigns.scope
    project_id = socket.assigns.project.id

    socket =
      socket
      |> assign(
        status_setup?: setup_configured?(Status.workspace_page(scope)),
        changelog_setup?: setup_configured?(Changelog.get_changelog(project_id, actor: scope))
      )

    case PublicPages.get_for_project(scope, project_id) do
      {:ok, public_page} ->
        socket |> assign(public_page: public_page, load_state: :ready) |> load_public_aliases()

      {:error, :not_found} ->
        assign(socket,
          public_aliases: [],
          # Only the first-run card below reads this.
          agent_state: AlplusWeb.AgentConnection.state(scope),
          load_state: :ready
        )

      {:error, _reason} ->
        assign(socket, load_state: :unavailable)
    end
  rescue
    _error -> assign(socket, load_state: :unavailable)
  end

  defp load_public_aliases(socket) do
    case PublicPages.aliases_for_project(socket.assigns.scope, socket.assigns.project.id) do
      {:ok, aliases} -> assign(socket, :public_aliases, aliases)
      {:error, _reason} -> assign(socket, load_state: :unavailable)
    end
  end

  defp setup_configured?({:ok, _resource}), do: true
  defp setup_configured?({:error, :not_found}), do: false
  defp setup_configured?({:error, _}), do: false

  defp public_page_url(%{public_slug: slug}), do: ~p"/status/#{slug}"

  defp connect_path(org_token, project),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project.public_token}/connect"
end
