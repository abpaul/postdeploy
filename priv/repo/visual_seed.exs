defmodule Alplus.VisualSeed do
  @moduledoc false

  require Ash.Query

  alias Alplus.{Monitoring, Orgs, Projects, PublicPages, Scope, Status}
  alias Alplus.Accounts.User
  alias Alplus.Monitoring.Incident
  alias Alplus.Status.{StatusIncident, StatusIncidentUpdate}

  @email "visual-review@example.com"
  @password "visual-review-only"
  @org_name "Visual Review"
  @project_name "Status Page UX"
  @status_slug "visual-review-status"

  def run do
    ensure_development!()
    Logger.configure(level: :warning)

    user = find_or_create_user()
    user_scope = Scope.for_user(user.id)
    org = find_or_create_org(user_scope)
    {:ok, org_scope} = Orgs.build_scope(user_scope, org.id)
    project = find_or_create_project(org_scope, org.id)
    project_scope = Scope.put_project(org_scope, project.id)

    api_monitor =
      find_or_create_monitor(project_scope, org.id, project.id, "api.side-project.dev")

    web_monitor =
      find_or_create_monitor(project_scope, org.id, project.id, "www.side-project.dev")

    page = find_or_create_page(project_scope, org.id, project.id)

    :ok = Status.set_monitor_visibility(project_scope, page, api_monitor.id, true)
    :ok = Status.set_monitor_visibility(project_scope, page, web_monitor.id, true)

    incident = find_or_create_incident(project_scope, org.id, project.id, api_monitor.id)
    public_incident = find_or_publish_incident(project_scope, page, incident)
    ensure_incident_update(project_scope, org.id, project.id, public_incident)
    page = publish_page(project_scope, page)

    path =
      "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor/status-pages/#{page.id}"

    IO.puts("Visual review workspace is ready.")
    IO.puts("Open http://localhost:4000#{path}")
    IO.puts("Use the documented local account in README.md.")
  end

  defp ensure_development! do
    if Mix.env() != :dev do
      raise "visual_seed.exs is development-only; run it with MIX_ENV=dev"
    end
  end

  defp find_or_create_user do
    query =
      User
      |> Ash.Query.for_read(:read, %{}, authorize?: false)
      |> Ash.Query.filter(email == ^@email)

    case Ash.read_one!(query) do
      nil ->
        Ash.Seed.seed!(User, %{
          email: @email,
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now()
        })

      user ->
        user
    end
  end

  defp find_or_create_org(scope) do
    Orgs.list_organizations!(actor: scope)
    |> Enum.find(&(&1.name == @org_name))
    |> case do
      nil -> Orgs.create_organization!(%{name: @org_name}, actor: scope)
      org -> org
    end
  end

  defp find_or_create_project(scope, org_id) do
    Projects.list_projects_for_org!(org_id, actor: scope)
    |> Enum.find(&(&1.name == @project_name))
    |> case do
      nil -> Projects.create_project!(%{org_id: org_id, name: @project_name}, actor: scope)
      project -> project
    end
  end

  defp find_or_create_monitor(scope, org_id, project_id, name) do
    Monitoring.list_monitors_for_project!(project_id, actor: scope)
    |> Enum.find(&(&1.name == name))
    |> case do
      nil ->
        Monitoring.create_monitor!(
          %{org_id: org_id, project_id: project_id, type: "http", name: name},
          actor: scope
        )

      monitor ->
        monitor
    end
  end

  defp find_or_create_page(scope, org_id, project_id) do
    case Status.workspace_page(scope) do
      {:error, :not_found} ->
        result!(
          Status.create_page(scope, %{
            org_id: org_id,
            project_id: project_id,
            status_slug: @status_slug,
            title: "Side Project Status"
          })
        )

      {:ok, page} ->
        page

      {:error, reason} ->
        raise "could not load the visual-review status workspace: #{inspect(reason)}"
    end
  end

  defp find_or_create_incident(scope, org_id, project_id, monitor_id) do
    Monitoring.list_incidents!(actor: scope)
    |> Enum.find(&(&1.monitor_id == monitor_id and &1.status == :open))
    |> case do
      nil ->
        Incident
        |> Ash.Changeset.for_create(
          :open,
          %{
            org_id: org_id,
            project_id: project_id,
            monitor_id: monitor_id,
            cause: "availability",
            started_at: DateTime.utc_now(),
            checks_failed_count: 3
          },
          actor: scope,
          authorize?: false
        )
        |> Ash.create!()

      incident ->
        incident
    end
  end

  defp find_or_publish_incident(scope, page, incident) do
    query =
      StatusIncident
      |> Ash.Query.for_read(:for_page, %{status_page_id: page.id}, actor: scope)
      |> Ash.Query.filter(incident_id == ^incident.id and status == "open")

    case Ash.read_one!(query) do
      nil ->
        result!(
          Status.publish_incident(scope, %{
            org_id: page.org_id,
            project_id: page.project_id,
            status_page_id: page.id,
            incident_id: incident.id,
            title: "API availability incident",
            body: "We are investigating failed requests to the API."
          })
        )

      public_incident ->
        public_incident
    end
  end

  defp ensure_incident_update(scope, org_id, project_id, public_incident) do
    query =
      StatusIncidentUpdate
      |> Ash.Query.for_read(:read, %{}, actor: scope)
      |> Ash.Query.filter(status_incident_id == ^public_incident.id)

    if Ash.read!(query) == [] do
      result!(
        Status.publish_incident_update(scope, %{
          org_id: org_id,
          project_id: project_id,
          status_incident_id: public_incident.id,
          body: "The team has isolated the failing dependency."
        })
      )
    end

    :ok
  end

  defp publish_page(scope, page) do
    case PublicPages.get_for_project(scope, page.project_id) do
      {:ok, %{published_at: published_at}} when not is_nil(published_at) -> page
      {:ok, _identity} -> result!(Status.publish_page(scope, page))
      {:error, reason} -> raise "could not load the visual-review public identity: #{inspect(reason)}"
    end
  end

  defp result!({:ok, value}), do: value
end

Alplus.VisualSeed.run()
