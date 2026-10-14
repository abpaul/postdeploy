defmodule AlplusWeb.Analytics.Context do
  @moduledoc """
  The mount and load steps every product-analytics screen repeats.

  Each screen resolves the same organization, the same project, the same
  project-scoped actor, and the same date range, so the resolution lives
  here once and a screen only states what it reads.
  """

  import Phoenix.Component, only: [assign: 3, assign: 2]

  alias Alplus.Analytics.Queries

  @doc """
  Mounts a project-scoped analytics screen.

  Assigns `:project`, `:project_scope`, `:window`, and the shell's own
  context. Raises `AlplusWeb.NotFoundError` for a cross-tenant reference,
  exactly like every other project screen.
  """
  @spec mount(map(), Phoenix.LiveView.Socket.t(), String.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(%{"org_token" => org_token, "project_token" => project_token}, socket, page_title) do
    with {:ok, socket} <-
           AlplusWeb.OrgContext.mount(org_token, socket,
             page_title: page_title,
             active: :analytics
           ) do
      project = AlplusWeb.OrgContext.project_for_token!(socket, project_token)

      project_scope = Alplus.Scope.put_project(socket.assigns.scope, project.id)

      {:ok,
       assign(socket,
         project: project,
         projects: [project],
         project_scope: project_scope,
         # Every screen offers the App picker, so every screen loads the
         # project's write keys. One indexed read per mount.
         analytics_sources: analytics_sources(project_scope),
         source_id: nil,
         window: "30d",
         loading?: true,
         load_failed?: false
       )}
    end
  end

  @doc "Reads and normalizes the window from the URL."
  @spec put_window(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def put_window(socket, params),
    do: assign(socket, :window, Queries.valid_window(params["window"]))

  @doc """
  Reads the selected app from the URL.

  A reference that is not one of this project's own write keys resolves to
  "all apps". The queries scope by organization and project anyway, so a
  foreign id could never read another tenant; refusing it here means the
  reader sees every app rather than an inexplicably empty screen.
  """
  @spec put_source(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def put_source(socket, params) do
    known = Enum.map(socket.assigns.analytics_sources, & &1.id)
    requested = params["source"]

    assign(socket, :source_id, if(requested in known, do: requested))
  end

  @doc "The query options every analytics read on a screen shares."
  @spec read_opts(Phoenix.LiveView.Socket.t()) :: keyword()
  def read_opts(socket) do
    case socket.assigns.source_id do
      nil -> []
      source_id -> [source_id: source_id]
    end
  end

  @doc """
  Runs `fun`, turning a database failure into a scoped error state rather
  than a crashed screen (ARCHITECTURE.md §9: scoped error boundaries).
  """
  @spec load(Phoenix.LiveView.Socket.t(), (-> keyword() | map())) :: Phoenix.LiveView.Socket.t()
  def load(socket, fun) do
    assigns = fun.()
    socket |> assign(assigns) |> assign(loading?: false, load_failed?: false)
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      require Logger
      Logger.error("analytics screen load failed: #{Exception.message(error)}")
      assign(socket, loading?: false, load_failed?: true)
  end

  @doc "The base path of a project's analytics area."
  @spec path(map(), String.t(), map()) :: String.t()
  def path(assigns, suffix \\ "", params \\ %{}) do
    base =
      "/dashboard/orgs/#{assigns.org.public_token}/projects/#{assigns.project.public_token}/analytics"

    query = if params == %{}, do: "", else: "?" <> URI.encode_query(params)
    base <> suffix <> query
  end

  @doc """
  Returns the project's active analytics write keys, newest first.

  A project holds one key per application, so this is also the App picker's
  option list. A screen never needs the secret, which exists only at
  creation.
  """
  @spec analytics_sources(Alplus.Scope.t()) :: [Alplus.Sources.Source.t()]
  def analytics_sources(scope) do
    scope.project_id
    |> Alplus.Sources.list_sources_for_project!(actor: scope)
    |> Enum.filter(&(&1.type == :analytics and &1.status == :active))
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  @doc "The project's saved analytics settings, or `nil`."
  @spec settings(Alplus.Scope.t()) :: Alplus.Analytics.Settings.t() | nil
  def settings(scope) do
    case Alplus.Analytics.get_settings_for_project(scope.project_id, actor: scope) do
      {:ok, settings} -> settings
      _ -> nil
    end
  end
end
