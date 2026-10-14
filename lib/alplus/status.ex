defmodule Alplus.Status do
  @moduledoc """
  Public Monitor status pages.

  Monitor remains the source of observed health. This domain stores only the
  public grouping and the human-written incident narrative.

  This module is also the public code interface for status-page authoring.
  """

  use Ash.Domain, otp_app: :alplus

  resources do
    resource Alplus.Status.StatusPage
    resource Alplus.Status.StatusComponent
    resource Alplus.Status.StatusComponentMonitor
    resource Alplus.Status.StatusIncident
    resource Alplus.Status.StatusIncidentUpdate
    resource Alplus.Status.ScheduledMaintenance
    resource Alplus.Status.MaintenanceMonitor
    resource Alplus.Status.StatusAnnouncement
    resource Alplus.Status.StatusIncidentDraft
  end

  require Ash.Query

  @incident_service_states ~w(outage degraded maintenance operational)

  alias Alplus.Repo

  alias Alplus.Status.{
    MaintenanceMonitor,
    Queries,
    ScheduledMaintenance,
    StatusAnnouncement,
    StatusComponent,
    StatusComponentMonitor,
    StatusIncident,
    StatusIncidentDraft,
    StatusIncidentUpdate,
    StatusPage
  }

  @max_incidents 100
  @max_updates 100
  @max_incident_services 100
  @max_incident_service_links @max_incidents * @max_incident_services

  @doc """
  Aggregates the customer-visible status from service rows and page signals.

  Empty workspaces keep their caller-specific presentation state. Public pages
  use `:unknown`; the authenticated workspace uses `:unconfigured`.
  """
  @spec aggregate_health([map()], boolean(), atom() | nil, atom()) :: atom()
  defdelegate aggregate_health(
                services,
                maintenance? \\ false,
                incident_status \\ nil,
                empty_state \\ :unknown
              ),
              to: Alplus.Status.Health

  @doc "Returns the newest published incident or announcement update."
  @spec last_public_update_at(Alplus.Scope.t(), String.t(), list(), list()) ::
          DateTime.t() | nil
  defdelegate last_public_update_at(scope, page_id, incidents, announcements),
    to: Alplus.Status.Health

  def ensure_page(scope, attrs \\ %{})

  def ensure_page(scope, attrs) when is_map(attrs) do
    case workspace_page(scope) do
      {:ok, page} ->
        {:ok, page}

      {:error, :not_found} ->
        create_page(scope, attrs)

      {:error, _} = error ->
        error
    end
  end

  def ensure_page(_scope, _attrs), do: {:error, :invalid_argument}

  def create_page(scope, attrs) do
    # Keep identity and workspace creation atomic. The transaction advisory
    # lock closes the race between two first-run setup requests, while rollback
    # prevents a failed workspace insert from leaving an orphan identity.
    case Ash.transact([Alplus.PublicPages.PublicPage, StatusPage], fn ->
           :ok = Queries.lock_project!(scope.project_id)

           case create_page_unlocked(scope, attrs) do
             {:ok, page} -> page
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, page} = result ->
        Alplus.Audit.write(%{
          actor: scope,
          org_id: page.org_id,
          project_id: page.project_id,
          action: "status_page.create",
          subject_type: "status_page",
          subject_id: page.id,
          outcome: "allowed",
          metadata: %{}
        })

        result

      {:error, %Ash.Error.Unknown.UnknownError{error: :status_pages_singleton}} ->
        {:error, :status_pages_singleton}

      {:error, %Ash.Error.Unknown.UnknownError{error: "unknown error: :status_pages_singleton"}} ->
        {:error, :status_pages_singleton}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_page_unlocked(scope, attrs) do
    with :ok <- ensure_single_workspace(scope),
         {:ok, _identity} <-
           Alplus.PublicPages.ensure_identity(scope, %{
             org_id: attr(attrs, :org_id, scope.org_id),
             project_id: attr(attrs, :project_id, scope.project_id),
             public_slug: attr(attrs, :public_slug, attr(attrs, :status_slug)),
             title: attr(attrs, :title),
             logo_url: attr(attrs, :logo_url)
           }) do
      Ash.create(
        StatusPage,
        %{
          org_id: attr(attrs, :org_id, scope.org_id),
          project_id: attr(attrs, :project_id, scope.project_id)
        },
        action: :create_internal,
        actor: scope
      )
    end
  end

  def publish_page(scope, page) do
    with {:ok, page} <- scoped_page(scope, page),
         true <- page_has_service?(scope, page.id),
         {:ok, identity} <- ensure_identity(scope, page),
         {:ok, _published} <- Alplus.PublicPages.publish(scope, identity) do
      Alplus.Measure.PublicCache.clear()
      {:ok, page}
    else
      false -> {:error, :service_required}
      {:error, _} = error -> error
    end
  end

  def unpublish_page(scope, page) do
    with {:ok, page} <- scoped_page(scope, page),
         {:ok, identity} <- Alplus.PublicPages.get_for_project(scope, page.project_id),
         {:ok, _unpublished} <- Alplus.PublicPages.unpublish(scope, identity) do
      clear_status_cache()
      {:ok, page}
    end
  end

  def update_page(scope, page, attrs) do
    with {:ok, page} <- scoped_page(scope, page),
         {:ok, identity} <- Alplus.PublicPages.get_for_project(scope, page.project_id),
         {:ok, _updated} <-
           Alplus.PublicPages.update(scope, identity, %{
             title: attr(attrs, :title),
             logo_url: attr(attrs, :logo_url)
           }) do
      clear_status_cache()
      {:ok, page}
    end
  end

  @doc "Returns the project's one legacy Status workspace, if it exists."
  def workspace_page(scope) do
    StatusPage
    |> Ash.Query.filter(org_id == ^scope.org_id and project_id == ^scope.project_id)
    |> Ash.read(actor: scope)
    |> case do
      {:ok, pages} when pages != [] -> {:ok, Enum.min_by(pages, &workspace_page_key/1)}
      {:ok, []} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @doc "Returns a Status workspace only when it belongs to the scoped project."
  def page_for_scope(scope, page_id) when is_binary(page_id), do: scoped_page(scope, page_id)
  def page_for_scope(_scope, _page_id), do: {:error, :not_found}

  defp workspace_page_key(page) do
    {
      page.inserted_at || ~U[9999-12-31 23:59:59Z],
      page.id
    }
  end

  defp ensure_identity(scope, page) do
    Alplus.PublicPages.get_for_project(scope, page.project_id)
  end

  defp ensure_single_workspace(scope) do
    case workspace_page(scope) do
      {:ok, _page} -> {:error, :status_pages_singleton}
      {:error, :not_found} -> :ok
      {:error, _} = error -> error
    end
  end

  def create_component(scope, attrs) when is_map(attrs) do
    with {:ok, page} <- scoped_page(scope, attr(attrs, :status_page_id)),
         attrs <- put_default_position(attrs, scope, page.id),
         {:ok, component} <- Ash.create(StatusComponent, attrs, action: :create, actor: scope) do
      clear_status_cache()
      {:ok, component}
    end
  end

  @doc "Creates one customer-facing service and connects its monitors atomically."
  def create_service(scope, attrs) when is_map(attrs) do
    monitor_ids = attrs |> attr(:monitor_ids, []) |> List.wrap() |> Enum.uniq()
    service_attrs = Map.drop(attrs, [:monitor_ids, "monitor_ids"])

    with {:ok, page} <- scoped_page(scope, attr(service_attrs, :status_page_id)),
         :ok <- validate_service_monitors(scope, page, monitor_ids),
         :ok <- ensure_service_name_free(scope, page.id, attr(service_attrs, :name), nil),
         service_attrs <- put_default_position(service_attrs, scope, page.id) do
      case Repo.transaction(fn ->
             case Ash.create(StatusComponent, service_attrs,
                    action: :create,
                    actor: scope,
                    return_notifications?: true,
                    context: %{warn_on_transaction_hooks?: false}
                  ) do
               {:ok, service, notifications} ->
                 # credo:disable-for-next-line Credo.Check.Refactor.Nesting
                 case link_service_monitors(scope, service, monitor_ids) do
                   :ok -> {service, notifications}
                   {:error, reason} -> Repo.rollback(reason)
                 end

               {:error, reason} ->
                 Repo.rollback(reason)
             end
           end) do
        {:ok, {service, notifications}} ->
          Ash.Notifier.notify(notifications)
          Alplus.Measure.PublicCache.clear()
          {:ok, service}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def update_service(scope, service, attrs) do
    with {:ok, existing} <- scoped_service(scope, service),
         :ok <-
           ensure_service_name_free(
             scope,
             existing.status_page_id,
             attr(attrs, :name, existing.name),
             existing.id
           ) do
      update_component(scope, existing, attrs)
    end
  end

  def delete_service(scope, service) do
    with {:ok, service} <- scoped_service(scope, service),
         false <- service_has_open_incident?(scope, service.id),
         result <- Ash.destroy(service, action: :destroy, actor: scope) do
      Alplus.Measure.PublicCache.clear()
      result
    else
      true -> {:error, :service_has_active_incident}
      {:error, _} = error -> error
    end
  end

  def connect_service_monitors(scope, service, monitor_ids) when is_list(monitor_ids) do
    with {:ok, service} <- scoped_service(scope, service),
         false <- service_has_open_incident?(scope, service.id),
         :ok <- validate_service_monitors(scope, service, monitor_ids),
         :ok <- sync_service_monitors(scope, service, Enum.uniq(monitor_ids)) do
      Alplus.Measure.PublicCache.clear()
      :ok
    else
      true -> {:error, :service_has_active_incident}
      {:error, _} = error -> error
    end
  end

  @doc "Loads the bounded, project-scoped service read model for a Status workspace."
  def service_overview(scope, page, options \\ []) when is_list(options) do
    Alplus.Status.ServiceOverview.list(scope, page, options)
  end

  @doc "Loads one project-scoped service, including optional reliability evidence."
  def service(scope, page, service_id, options \\ []) when is_list(options) do
    Alplus.Status.ServiceOverview.get(scope, page, service_id, options)
  end

  @doc "Reorders every service in a scoped Status workspace as one transaction."
  def order_services(scope, page, service_ids) when is_list(service_ids) do
    with {:ok, page} <- scoped_page(scope, page),
         {:ok, services} <- service_overview(scope, page),
         current_ids <- Enum.map(services, & &1.id),
         true <- length(service_ids) == length(Enum.uniq(service_ids)),
         true <- MapSet.new(service_ids) == MapSet.new(current_ids),
         {:ok, :ok} <-
           Ash.transact(StatusComponent, fn ->
             Enum.reduce_while(Enum.with_index(service_ids), :ok, fn {service_id, position},
                                                                     :ok ->
               case Enum.find(services, &(&1.id == service_id)) do
                 nil ->
                   {:halt, {:error, :not_found}}

                 service ->
                   case scoped_service(scope, service.id) do
                     {:ok, component} ->
                       case Ash.update(component, %{position: position},
                              action: :update,
                              actor: scope
                            ) do
                         {:ok, _component} -> {:cont, :ok}
                         {:error, reason} -> {:halt, {:error, reason}}
                       end

                     {:error, reason} ->
                       {:halt, {:error, reason}}
                   end
               end
             end)
           end) do
      clear_status_cache()
      {:ok, service_ids}
    else
      false -> {:error, :invalid_service_order}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, _} = error -> error
    end
  end

  def order_services(_scope, _page, _service_ids), do: {:error, :invalid_service_order}

  @doc "Lists bounded announcements for one authenticated Status workspace."
  def list_announcements(scope, page) do
    with {:ok, page} <- scoped_page(scope, page) do
      StatusAnnouncement
      |> Ash.Query.for_read(:for_page, %{status_page_id: page.id}, actor: scope)
      |> Ash.Query.sort(published_at: :desc, id: :desc)
      |> Ash.Query.limit(100)
      |> Ash.read()
      |> unwrap_page()
    end
  end

  @doc "Gets one announcement only when it belongs to the scoped Status workspace."
  def announcement(scope, page, announcement_id) when is_binary(announcement_id) do
    with {:ok, page} <- scoped_page(scope, page),
         {:ok, announcement} <- scoped_announcement(scope, announcement_id),
         true <- announcement.status_page_id == page.id do
      {:ok, announcement}
    else
      false -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def announcement(_scope, _page, _announcement_id), do: {:error, :not_found}

  @doc "Lists bounded maintenance windows for one authenticated Status workspace."
  def list_maintenances(scope, page) do
    with {:ok, page} <- scoped_page(scope, page) do
      ScheduledMaintenance
      |> Ash.Query.for_read(:for_page, %{status_page_id: page.id}, actor: scope)
      |> Ash.Query.sort(starts_at: :desc, id: :desc)
      |> Ash.Query.limit(100)
      |> Ash.read()
      |> unwrap_page()
    end
  end

  @doc "Gets one maintenance window only when it belongs to the scoped workspace."
  def maintenance(scope, page, maintenance_id) when is_binary(maintenance_id) do
    with {:ok, page} <- scoped_page(scope, page),
         {:ok, maintenance} <- scoped_maintenance(scope, maintenance_id),
         true <- maintenance.status_page_id == page.id do
      {:ok, maintenance}
    else
      false -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def maintenance(_scope, _page, _maintenance_id), do: {:error, :not_found}

  @doc "Lists Status incidents for one scoped page with bounded service links."
  def list_incidents(scope, page_id, _options \\ []) do
    with {:ok, page} <- scoped_page(scope, page_id),
         action <- if(manager?(scope), do: :operator_for_page, else: :for_page),
         {:ok, incidents} <- read_incidents(scope, action, page.id) do
      {:ok, attach_incident_services(scope, incidents)}
    end
  end

  @doc "Loads one Status incident and its bounded timeline under the project scope."
  def incident_overview(scope, incident_or_id) do
    manager? = manager?(scope)

    with {:ok, incident} <- read_incident(scope, incident_or_id, manager?),
         {:ok, updates} <- incident_updates(scope, incident.id),
         draft <- if(manager?, do: draft_for_incident(scope, incident.id), else: nil) do
      {:ok,
       %{
         incident: incident,
         updates: updates,
         affected_services: incident_services(scope, incident.id),
         draft: draft,
         detected_incident:
           if(manager?, do: detected_incident(scope, incident.incident_id), else: nil)
       }}
    end
  end

  def update_component(scope, component, attrs) do
    with {:ok, component} <- scoped_service(scope, component) do
      case Ash.update(component, attrs, action: :update, actor: scope) do
        {:ok, _updated} = result ->
          clear_status_cache()
          result

        other ->
          other
      end
    end
  end

  # The join rows cascade at the database (`status_component_monitors`
  # references components with ON DELETE CASCADE), so hiding a component
  # is one destroy.
  def delete_component(scope, component) do
    with {:ok, component} <- scoped_service(scope, component),
         false <- service_has_open_incident?(scope, component.id) do
      case Ash.destroy(component, action: :destroy, actor: scope) do
        {:ok, _destroyed} = result ->
          clear_status_cache()
          result

        other ->
          other
      end
    else
      true -> {:error, :service_has_active_incident}
      {:error, _} = error -> error
    end
  end

  def link_monitor(scope, component, monitor_id) do
    with {:ok, component} <- scoped_service(scope, component),
         {:ok, monitor} <- scoped_monitor(scope, monitor_id),
         {:ok, _} <- ensure_component_project(component, monitor),
         {:ok, _link, _notifications} <-
           Ash.create(
             StatusComponentMonitor,
             %{
               status_component_id: component.id,
               monitor_id: monitor.id,
               org_id: component.org_id,
               project_id: component.project_id
             },
             action: :link,
             actor: scope,
             return_notifications?: true
           ) do
      clear_status_cache()
      :ok
    end
  end

  def unlink_monitor(scope, component, monitor_id) do
    with {:ok, component} <- scoped_service(scope, component),
         false <- service_has_open_incident?(scope, component.id),
         {:ok, _monitor} <- scoped_monitor(scope, monitor_id),
         :ok <- destroy_component_monitor_link(scope, component, monitor_id) do
      clear_status_cache()
      :ok
    else
      true -> {:error, :service_has_active_incident}
      {:error, _} = error -> error
    end
  end

  def set_monitor_visibility(scope, page, monitor_id, visible?) when is_boolean(visible?) do
    with {:ok, page} <- scoped_page(scope, page),
         {:ok, monitor} <- scoped_monitor(scope, monitor_id),
         false <- not visible? and monitor_has_open_incident?(scope, page.id, monitor.id) do
      case Repo.transaction(fn ->
             case set_monitor_visibility_in_transaction(scope, page, monitor, visible?) do
               {:ok, notifications} -> notifications
               {:error, reason} -> Repo.rollback(reason)
             end
           end) do
        {:ok, notifications} ->
          Ash.Notifier.notify(notifications)
          clear_status_cache()
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      true -> {:error, :service_has_active_incident}
    end
  end

  @doc "Publishes a customer incident and links all affected services atomically."
  def publish_incident(scope, attrs), do: create_incident(scope, attrs)

  def create_incident(scope, attrs) when is_map(attrs) do
    service_ids = attrs |> attr(:service_ids, []) |> List.wrap() |> Enum.uniq()
    service_states = attr(attrs, :service_states, %{})

    incident_attrs =
      Map.drop(attrs, [:service_ids, "service_ids", :service_states, "service_states"])

    with {:ok, page} <- scoped_page(scope, attr(incident_attrs, :status_page_id)),
         :ok <- validate_incident_services(scope, page, service_ids),
         {:ok, service_states} <- normalize_incident_service_states(service_states, service_ids) do
      case Repo.transaction(fn ->
             case Ash.create(StatusIncident, incident_attrs,
                    action: :publish,
                    actor: scope,
                    return_notifications?: true,
                    context: %{warn_on_transaction_hooks?: false}
                  ) do
               {:ok, incident, notifications} ->
                 # credo:disable-for-next-line Credo.Check.Refactor.Nesting
                 case link_incident_services(scope, incident, service_ids, service_states) do
                   :ok -> {incident, notifications}
                   {:error, reason} -> Repo.rollback(reason)
                 end

               {:error, reason} ->
                 Repo.rollback(reason)
             end
           end) do
        {:ok, {incident, notifications}} ->
          Ash.Notifier.notify(notifications)
          clear_status_cache()
          {:ok, incident}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Creates an unpublished draft from a monitor failure."
  def create_incident_draft(scope, attrs) when is_map(attrs) do
    monitor_id = attr(attrs, :monitor_id)
    status_page_id = attr(attrs, :status_page_id)

    with {:ok, page} <- scoped_page(scope, status_page_id),
         {:ok, monitor} <- scoped_monitor(scope, monitor_id),
         true <- monitor.project_id == page.project_id,
         {:ok, draft} <-
           Ash.create(
             StatusIncident,
             %{
               org_id: page.org_id,
               project_id: page.project_id,
               status_page_id: page.id,
               incident_id: open_monitor_incident_id(scope, monitor.id),
               title: attr(attrs, :title, "Service disruption"),
               body: attr(attrs, :body, "We are investigating the issue."),
               stage: attr(attrs, :stage, "investigating"),
               next_update_at: attr(attrs, :next_update_at)
             },
             action: :draft,
             actor: scope
           ) do
      suggested = unhealthy_service_ids(scope, page.id)

      with {:ok, _server_draft} <-
             save_incident_draft(scope, %{
               status_incident_id: draft.id,
               monitor_id: monitor.id,
               title: draft.title,
               body: draft.body,
               suggested_service_ids: suggested
             }) do
        {:ok, draft |> Map.put(:private?, true) |> Map.put(:suggested_service_ids, suggested)}
      end
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  @doc "Creates one private Status draft for every page that exposes a failed monitor."
  def create_failure_drafts(org_id, project_id, monitor_id, incident_id)
      when is_binary(org_id) and is_binary(project_id) and is_binary(monitor_id) and
             is_binary(incident_id) do
    case Repo.transaction(fn ->
           org_id
           |> Queries.pages_with_monitor(project_id, monitor_id)
           |> Enum.map(&upsert_failure_draft(org_id, project_id, &1, monitor_id, incident_id))
         end) do
      {:ok, drafts} -> {:ok, drafts}
      {:error, reason} -> {:error, reason}
    end
  end

  def create_failure_drafts(_org_id, _project_id, _monitor_id, _incident_id),
    do: {:error, :invalid_args}

  @doc false
  def create_failure_draft(org_id, project_id, page_id, monitor_id, incident_id)
      when is_binary(org_id) and is_binary(project_id) and is_binary(page_id) and
             is_binary(monitor_id) and is_binary(incident_id) do
    if Queries.monitor_incident_exists?(org_id, project_id, monitor_id, incident_id) and
         page_id in Queries.pages_with_monitor(org_id, project_id, monitor_id) do
      case Repo.transaction(fn ->
             upsert_failure_draft(org_id, project_id, page_id, monitor_id, incident_id)
           end) do
        {:ok, draft} -> {:ok, draft}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, {:permanent, "status_page_not_found_for_monitor_scope"}}
    end
  end

  def create_failure_draft(_org_id, _project_id, _page_id, _monitor_id, _incident_id),
    do: {:error, {:permanent, "invalid_incident_draft_identity"}}

  def publish_incident_draft(scope, draft, attrs \\ %{}) do
    with {:ok, draft} <- scoped_incident(scope, draft),
         {:ok, page} <- scoped_page(scope, draft.status_page_id),
         {:ok, server_draft} <- incident_draft(scope, draft.id),
         service_ids <-
           attrs
           |> attr(:service_ids)
           |> (case do
                 nil -> (server_draft && server_draft.suggested_service_ids) || []
                 ids -> List.wrap(ids)
               end)
           |> Enum.uniq(),
         service_states_attrs <-
           attr(attrs, :service_states, (server_draft && server_draft.service_states) || %{}),
         {:ok, service_states} <-
           normalize_incident_service_states(service_states_attrs, service_ids),
         :ok <- validate_incident_services(scope, page, service_ids),
         {:ok, incident} <-
           Ash.update(
             draft,
             Map.drop(attrs, [:service_ids, "service_ids", :service_states, "service_states"]),
             action: :publish_draft,
             actor: scope
           ),
         :ok <- link_incident_services(scope, incident, service_ids, service_states) do
      clear_incident_draft(scope, incident)
      clear_status_cache()
      {:ok, incident}
    end
  end

  def update_incident(scope, incident, attrs) do
    with {:ok, incident} <- scoped_incident(scope, incident),
         :ok <- reject_direct_resolution(attrs),
         :ok <- ensure_stage_change_allowed(incident, attrs) do
      case Ash.update(incident, attrs, action: :update_content, actor: scope) do
        {:ok, _updated} = result ->
          clear_status_cache()
          result

        other ->
          other
      end
    end
  end

  def publish_incident_update(scope, attrs) when is_map(attrs) do
    incident_id = attr(attrs, :status_incident_id)
    next_update_at = attrs |> attr(:next_update_at) |> blank_to_nil()
    next_update_at_provided? = attr_provided?(attrs, :next_update_at)

    with {:ok, incident} <- scoped_incident(scope, incident_id),
         :ok <- ensure_incident_open(incident),
         {:ok, update} <-
           Ash.create(
             StatusIncidentUpdate,
             %{
               org_id: scope.org_id,
               project_id: scope.project_id,
               status_incident_id: incident.id,
               body: attr(attrs, :body)
             },
             action: :publish,
             actor: scope
           ),
         {:ok, _incident} <-
           maybe_update_next_target(scope, incident, next_update_at, next_update_at_provided?) do
      clear_incident_draft(scope, incident)
      clear_status_cache()
      {:ok, update}
    end
  end

  def publish_resolved_update(scope, attrs) when is_map(attrs) do
    incident_id = attr(attrs, :status_incident_id)

    case Repo.transaction(fn ->
           with {:ok, incident} <- scoped_incident(scope, incident_id),
                {:ok, _update, update_notifications} <-
                  Ash.create(
                    StatusIncidentUpdate,
                    %{
                      org_id: scope.org_id,
                      project_id: scope.project_id,
                      status_incident_id: incident.id,
                      body: attr(attrs, :body)
                    },
                    action: :publish,
                    actor: scope,
                    return_notifications?: true,
                    context: %{warn_on_transaction_hooks?: false}
                  ),
                {:ok, resolved, resolve_notifications} <-
                  Ash.update(incident, %{},
                    action: :resolve,
                    actor: scope,
                    return_notifications?: true,
                    context: %{warn_on_transaction_hooks?: false}
                  ) do
             {resolved, update_notifications ++ resolve_notifications}
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, {resolved, notifications}} ->
        Ash.Notifier.notify(notifications)
        clear_incident_draft(scope, resolved)
        clear_status_cache()
        {:ok, resolved}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def change_incident_stage(scope, incident, stage)
      when stage in ["investigating", "identified", "monitoring"] do
    with {:ok, incident} <- scoped_incident(scope, incident),
         :ok <- ensure_incident_open(incident) do
      case Ash.update(incident, %{stage: stage}, action: :update_content, actor: scope) do
        {:ok, _updated} = result ->
          clear_status_cache()
          result

        other ->
          other
      end
    end
  end

  def change_incident_stage(_scope, _incident, "resolved"),
    do: {:error, :resolution_update_required}

  def change_incident_stage(_scope, _incident, _stage), do: {:error, :invalid_stage}

  def save_incident_draft(scope, attrs) when is_map(attrs) do
    incident_id = attr(attrs, :status_incident_id)
    service_ids_provided? = attr_provided?(attrs, :suggested_service_ids)
    service_states_provided? = attr_provided?(attrs, :service_states)

    with {:ok, incident} <- scoped_incident(scope, incident_id),
         {:ok, existing_draft} <- incident_draft(scope, incident.id),
         service_ids <-
           (if service_ids_provided? do
              attrs |> attr(:suggested_service_ids, []) |> List.wrap() |> Enum.uniq()
            else
              (existing_draft && existing_draft.suggested_service_ids) || []
            end),
         service_states_attrs <- attr(attrs, :service_states, %{}),
         {:ok, service_states} <-
           (if service_states_provided? do
              normalize_incident_service_states(service_states_attrs, service_ids)
            else
              {:ok, nil}
            end),
         draft_attrs <- %{
           org_id: scope.org_id,
           project_id: scope.project_id,
           status_page_id: incident.status_page_id,
           status_incident_id: incident.id,
           monitor_id: attr(attrs, :monitor_id),
           title: attr(attrs, :title, "Service update"),
           body: attr(attrs, :body, "")
         },
         draft_attrs <-
           (if service_ids_provided? do
              Map.put(draft_attrs, :suggested_service_ids, service_ids)
            else
              draft_attrs
            end),
         draft_attrs <-
           (if service_states_provided? do
              Map.put(draft_attrs, :service_states, service_states)
            else
              draft_attrs
            end),
         draft_attrs <-
           (if attr_provided?(attrs, :next_update_at) do
              Map.put(draft_attrs, :next_update_at, blank_to_nil(attr(attrs, :next_update_at)))
            else
              draft_attrs
            end) do
      case existing_draft do
        %StatusIncidentDraft{} = draft ->
          Ash.update(
            draft,
            Map.take(
              draft_attrs,
              [:title, :body, :next_update_at, :suggested_service_ids, :service_states]
            ),
            action: :update,
            actor: scope
          )

        nil ->
          draft_attrs =
            draft_attrs
            |> Map.put_new(:suggested_service_ids, [])
            |> Map.put_new(:service_states, %{})

          Ash.create(StatusIncidentDraft, draft_attrs, action: :create, actor: scope)

        _ ->
          draft_attrs =
            draft_attrs
            |> Map.put_new(:suggested_service_ids, [])
            |> Map.put_new(:service_states, %{})

          Ash.create(StatusIncidentDraft, draft_attrs, action: :create, actor: scope)
      end
    end
  end

  def incident_draft(scope, incident_or_id) do
    incident_id = component_id(incident_or_id)

    StatusIncidentDraft
    |> Ash.Query.for_read(:for_incident, %{status_incident_id: incident_id}, actor: scope)
    |> Ash.read_one(actor: scope)
  end

  def clear_incident_draft(scope, incident_or_id) do
    case incident_draft(scope, incident_or_id) do
      {:ok, %StatusIncidentDraft{} = draft} ->
        Ash.destroy(draft, action: :destroy, actor: scope)

      {:ok, nil} ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc "One unattached draft by id, scoped to the actor's org and project."
  def page_incident_draft(scope, draft_id) when is_binary(draft_id) do
    case Ash.get(StatusIncidentDraft, draft_id, actor: scope) do
      {:ok, %StatusIncidentDraft{status_incident_id: nil, monitor_id: nil} = draft}
      when draft.org_id == scope.org_id and draft.project_id == scope.project_id ->
        {:ok, draft}

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Creates or updates one composer draft. Pass `:draft_id` to keep writing to the
  draft already open; omit it to start a new one.
  """
  def save_page_incident_draft(scope, attrs) when is_map(attrs) do
    with {:ok, page} <- scoped_page(scope, attr(attrs, :status_page_id)),
         service_ids <- attrs |> attr(:suggested_service_ids, []) |> List.wrap() |> Enum.uniq(),
         {:ok, service_states} <-
           normalize_incident_service_states(attr(attrs, :service_states, %{}), service_ids) do
      writable = %{
        title: attr(attrs, :title, "Service disruption"),
        body: attr(attrs, :body, "We are investigating the issue."),
        next_update_at: blank_to_nil(attr(attrs, :next_update_at)),
        suggested_service_ids: service_ids,
        service_states: service_states
      }

      case attr(attrs, :draft_id) do
        nil ->
          Ash.create(
            StatusIncidentDraft,
            Map.merge(writable, %{
              org_id: page.org_id,
              project_id: page.project_id,
              status_page_id: page.id
            }),
            action: :create,
            actor: scope
          )

        draft_id ->
          with {:ok, draft} <- page_incident_draft(scope, draft_id) do
            Ash.update(draft, writable, action: :update, actor: scope)
          end
      end
    end
  end

  def resolve_incident(scope, incident),
    do: resolve_incident_and_clear(scope, incident)

  def publish_announcement(scope, attrs) do
    with {:ok, page} <- scoped_page(scope, attr(attrs, :status_page_id)),
         attrs <-
           attrs
           |> Map.put(:org_id, page.org_id)
           |> Map.put(:project_id, page.project_id)
           |> Map.put(:status_page_id, page.id),
         {:ok, announcement} <-
           Ash.create(StatusAnnouncement, attrs, action: :publish, actor: scope) do
      clear_status_cache()
      {:ok, announcement}
    end
  end

  def update_announcement(scope, announcement, attrs) do
    with {:ok, announcement} <- scoped_announcement(scope, announcement) do
      case Ash.update(announcement, attrs, action: :update, actor: scope) do
        {:ok, _updated} = result ->
          clear_status_cache()
          result

        other ->
          other
      end
    end
  end

  def unpublish_announcement(scope, announcement),
    do: set_announcement_visibility(scope, announcement, :unpublish)

  def republish_announcement(scope, announcement),
    do: set_announcement_visibility(scope, announcement, :republish)

  defp set_announcement_visibility(scope, announcement, action) do
    with {:ok, announcement} <- scoped_announcement(scope, announcement) do
      case Ash.update(announcement, %{}, action: action, actor: scope) do
        {:ok, _updated} = result ->
          clear_status_cache()
          result

        other ->
          other
      end
    end
  end

  def schedule_maintenance(scope, attrs, monitor_ids) when is_list(monitor_ids) do
    with {:ok, page} <- scoped_page(scope, attr(attrs, :status_page_id)),
         attrs <-
           attrs
           |> Map.put(:org_id, page.org_id)
           |> Map.put(:project_id, page.project_id)
           |> Map.put(:status_page_id, page.id),
         :ok <- validate_monitor_ids(scope, attrs, monitor_ids),
         {:ok, maintenance} <- create_and_link_maintenance(scope, attrs, monitor_ids) do
      clear_status_cache()
      broadcast_monitor_update(scope.project_id)
      {:ok, maintenance}
    end
  end

  @doc """
  Cancels one scheduled or running window. A completed or already cancelled
  window is left alone, so a double click cannot resume a monitor twice.
  """
  def cancel_maintenance(scope, maintenance) do
    with {:ok, maintenance} <- scoped_maintenance(scope, maintenance) do
      if maintenance.status in ["scheduled", "active"] do
        case Alplus.Status.MaintenanceWorker.cancel(maintenance) do
          :ok ->
            clear_status_cache()
            {:ok, maintenance}

          {:error, reason} ->
            {:error, reason}
        end
      else
        {:error, :maintenance_not_cancellable}
      end
    end
  end

  defp scoped_maintenance(scope, maintenance) do
    case Ash.get(ScheduledMaintenance, component_id(maintenance), actor: scope) do
      {:ok, maintenance}
      when maintenance.org_id == scope.org_id and maintenance.project_id == scope.project_id ->
        {:ok, maintenance}

      _ ->
        {:error, :not_found}
    end
  end

  defp create_and_link_maintenance(scope, attrs, monitor_ids) do
    # Ash creates the maintenance row and this SQL writes its join rows on one
    # connection. Roll back both when any monitor link fails.
    case Repo.transaction(fn ->
           with {:ok, maintenance, notifications} <-
                  Ash.create(ScheduledMaintenance, attrs,
                    action: :schedule,
                    actor: scope,
                    return_notifications?: true,
                    context: %{warn_on_transaction_hooks?: false}
                  ),
                :ok <- link_maintenance_monitors(scope, maintenance, monitor_ids) do
             {maintenance, notifications}
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, {maintenance, notifications}} ->
        Ash.Notifier.notify(notifications)
        clear_status_cache()
        {:ok, maintenance}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upsert_failure_draft(org_id, project_id, page_id, monitor_id, incident_id) do
    # This is the narrow PostgreSQL identity exception. The lock serializes
    # callers while equivalent audit rows remain in the same transaction.
    :ok = Queries.lock_failure_draft!(org_id, project_id, page_id, incident_id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {status_incident_id, title, body, created?} =
      case Repo.query!(
             "SELECT id, title, body FROM status_incidents WHERE org_id = $1 AND project_id = $2 AND status_page_id = $3 AND incident_id = $4 AND is_private = true LIMIT 1",
             [org_id, project_id, page_id, incident_id]
           ) do
        %{rows: [[id, title, body]]} ->
          {id, title, body, false}

        %{rows: []} ->
          %{rows: [[id, title, body]]} =
            Repo.query!(
              """
              INSERT INTO status_incidents
                (id, org_id, project_id, status_page_id, incident_id, title, body, status, stage,
                 published_at, is_private, inserted_at, updated_at)
              VALUES ($1, $2, $3, $4, $5, $6, $7, 'open', 'investigating', NULL, true, $8, $8)
              RETURNING id, title, body
              """,
              [
                Alplus.Id.generate(:status_incident),
                org_id,
                project_id,
                page_id,
                incident_id,
                "Service disruption",
                "We are investigating the issue.",
                now
              ]
            )

          {id, title, body, true}
      end

    if created?,
      do:
        write_automation_audit!(
          org_id,
          project_id,
          status_incident_id,
          "status_incident.draft",
          "status_incident",
          now
        )

    suggested = Queries.unhealthy_component_ids_unscoped(org_id, project_id, page_id)

    %{rows: draft_rows} =
      Repo.query!(
        """
        INSERT INTO status_incident_drafts
          (id, org_id, project_id, status_page_id, monitor_id, status_incident_id, title, body,
           suggested_service_ids, service_states, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, '{}', $10, $10)
        ON CONFLICT (status_incident_id) WHERE status_incident_id IS NOT NULL DO NOTHING
        RETURNING id
        """,
        [
          Alplus.Id.generate(:status_incident_draft),
          org_id,
          project_id,
          page_id,
          monitor_id,
          status_incident_id,
          title,
          body,
          suggested,
          now
        ]
      )

    case draft_rows do
      [[draft_id]] ->
        write_automation_audit!(
          org_id,
          project_id,
          draft_id,
          "status_incident_draft.create",
          "status_incident_draft",
          now
        )

      [] ->
        :ok
    end

    status_incident_id
  end

  defp write_automation_audit!(org_id, project_id, subject_id, action, subject_type, now) do
    Repo.query!(
      """
      INSERT INTO audit_logs
        (id, org_id, project_id, actor_id, actor_kind, transport, action, subject_type,
         subject_id, outcome, metadata, inserted_at)
      VALUES ($1, $2, $3, NULL, 'system', 'automation', $4, $5, $6, 'allowed', $7::jsonb, $8)
      """,
      [
        Alplus.Id.generate("audit"),
        org_id,
        project_id,
        action,
        subject_type,
        subject_id,
        %{source: "monitor_incident_draft"},
        now
      ]
    )
  end

  defp validate_monitor_ids(scope, attrs, monitor_ids) do
    org_id = attr(attrs, :org_id)
    project_id = attr(attrs, :project_id)

    Enum.reduce_while(monitor_ids, :ok, fn monitor_id, :ok ->
      case scoped_monitor(scope, monitor_id) do
        {:ok, monitor}
        when monitor.org_id == org_id and monitor.project_id == project_id ->
          {:cont, :ok}

        _ ->
          {:halt, {:error, :not_found}}
      end
    end)
  end

  defp link_maintenance_monitors(scope, maintenance, monitor_ids) do
    Enum.reduce_while(monitor_ids, :ok, fn monitor_id, :ok ->
      case scoped_monitor(scope, monitor_id) do
        {:ok, monitor}
        when monitor.org_id == maintenance.org_id and monitor.project_id == maintenance.project_id ->
          case Ash.create(
                 MaintenanceMonitor,
                 %{
                   maintenance_id: maintenance.id,
                   monitor_id: monitor.id,
                   org_id: maintenance.org_id,
                   project_id: maintenance.project_id
                 },
                 action: :link,
                 actor: scope,
                 return_notifications?: true,
                 context: %{warn_on_transaction_hooks?: false}
               ) do
            {:ok, _link, _notifications} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        _ ->
          {:halt, {:error, :not_found}}
      end
    end)
  end

  defp scoped_monitor(scope, monitor_id) do
    Ash.get(Alplus.Monitoring.Monitor, monitor_id, actor: scope)
  end

  defp scoped_page(scope, page) do
    case Ash.get(StatusPage, component_id(page), actor: scope) do
      {:ok, page} when page.org_id == scope.org_id and page.project_id == scope.project_id ->
        {:ok, page}

      _ ->
        {:error, :not_found}
    end
  end

  defp set_monitor_visibility_in_transaction(scope, page, monitor, true) do
    with {:ok, component_ids} <- component_ids_for_monitor(scope, page.id, monitor.id) do
      case component_ids do
        [] -> create_monitor_component(scope, page, monitor)
        _component_ids -> {:ok, []}
      end
    end
  end

  defp set_monitor_visibility_in_transaction(scope, page, monitor, false) do
    with {:ok, component_ids} <- component_ids_for_monitor(scope, page.id, monitor.id) do
      Enum.reduce_while(component_ids, {:ok, []}, fn component_id, {:ok, notifications} ->
        with {:ok, component} <- Ash.get(StatusComponent, component_id, actor: scope),
             {:ok, component_notifications} <- remove_monitor_link(scope, component, monitor.id) do
          {:cont, {:ok, notifications ++ component_notifications}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp create_monitor_component(scope, page, monitor) do
    # A service name is unique per page, so a monitor whose name already names a
    # service joins that service instead of creating a second one with the same
    # customer-facing label.
    case Queries.component_id_by_name(scope, page.id, monitor.name) do
      {:ok, component_id} ->
        with {:ok, component} <- Ash.get(StatusComponent, component_id, actor: scope),
             :ok <- link_monitor(scope, component, monitor.id) do
          {:ok, []}
        end

      :none ->
        create_named_monitor_component(scope, page, monitor)
    end
  end

  defp create_named_monitor_component(scope, page, monitor) do
    position = Queries.next_component_position(scope, page.id)

    with {:ok, component, notifications} <-
           Ash.create(
             StatusComponent,
             %{
               org_id: scope.org_id,
               project_id: scope.project_id,
               status_page_id: page.id,
               name: monitor.name,
               position: position
             },
             action: :create,
             actor: scope,
             return_notifications?: true
           ),
         :ok <- link_monitor(scope, component, monitor.id) do
      {:ok, notifications}
    end
  end

  defp remove_monitor_link(scope, component, monitor_id) do
    link_count = Queries.component_monitor_link_count(scope, component.id)

    if link_count == 1 do
      case Ash.destroy(component,
             action: :destroy,
             actor: scope,
             return_notifications?: true
           ) do
        {:ok, _destroyed, notifications} -> {:ok, notifications}
        {:ok, _destroyed} -> {:ok, []}
        {:error, _} = error -> error
      end
    else
      case unlink_monitor(scope, component, monitor_id) do
        :ok -> {:ok, []}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp destroy_component_monitor_link(scope, component, monitor_id) do
    query =
      StatusComponentMonitor
      |> Ash.Query.for_read(:read, %{}, actor: scope)
      |> Ash.Query.filter(
        status_component_id == ^component.id and monitor_id == ^monitor_id and
          org_id == ^scope.org_id and project_id == ^scope.project_id
      )

    case Ash.read_one(query, actor: scope) do
      {:ok, nil} -> :ok
      {:ok, link} -> Ash.destroy(link, action: :unlink, actor: scope) |> discard_destroyed()
      {:error, reason} -> {:error, reason}
    end
  end

  defp discard_destroyed({:ok, _link}), do: :ok
  defp discard_destroyed({:error, reason}), do: {:error, reason}

  defp ensure_component_project(component, monitor)
       when component.org_id == monitor.org_id and component.project_id == monitor.project_id,
       do: {:ok, :same_scope}

  defp ensure_component_project(_component, _monitor), do: {:error, :not_found}

  defp attr(attrs, key, default \\ nil) when is_map(attrs) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp put_default_position(attrs, scope, page_id) do
    if is_nil(attr(attrs, :position)) do
      Map.put(attrs, :position, Queries.next_component_position(scope, page_id))
    else
      attrs
    end
  end

  defp scoped_service(scope, service) do
    case Ash.get(StatusComponent, component_id(service), actor: scope) do
      {:ok, service}
      when service.org_id == scope.org_id and service.project_id == scope.project_id ->
        {:ok, service}

      _ ->
        {:error, :not_found}
    end
  end

  defp page_has_service?(scope, page_id) do
    Queries.component_exists_with_monitor?(scope, page_id)
  end

  # A service name identifies one customer-facing thing, so two services on one
  # page may not share it. Compared with the same normalisation as the unique
  # index (`status_components_page_name_index`): case folded, ends trimmed.
  defp ensure_service_name_free(scope, status_page_id, name, exclude_service_id) do
    if service_name_taken?(scope, status_page_id, name, exclude_service_id) do
      {:error, :duplicate_service_name}
    else
      :ok
    end
  end

  @doc """
  Whether another service on this page already carries `name`.

  Callers use it to report the clash on the form the operator is filling in,
  rather than letting the unique index refuse the write afterwards.
  """
  @spec service_name_taken?(Alplus.Scope.t(), String.t(), String.t() | nil, String.t() | nil) ::
          boolean()
  defdelegate service_name_taken?(scope, status_page_id, name, exclude_service_id \\ nil),
    to: Queries

  defp validate_service_monitors(scope, page, monitor_ids) do
    Enum.reduce_while(monitor_ids, :ok, fn monitor_id, :ok ->
      case scoped_monitor(scope, monitor_id) do
        {:ok, monitor}
        when monitor.org_id == page.org_id and monitor.project_id == page.project_id ->
          {:cont, :ok}

        _ ->
          {:halt, {:error, :not_found}}
      end
    end)
  end

  defp link_service_monitors(scope, service, monitor_ids) do
    Enum.reduce_while(monitor_ids, :ok, fn monitor_id, :ok ->
      case link_monitor(scope, service, monitor_id) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp sync_service_monitors(scope, service, monitor_ids) do
    with {:ok, existing_ids} <- service_monitor_ids(scope, service.id) do
      existing = MapSet.new(existing_ids)
      desired = MapSet.new(monitor_ids)

      with :ok <-
             Enum.reduce_while(MapSet.difference(existing, desired), :ok, fn monitor_id, :ok ->
               case unlink_monitor(scope, service, monitor_id) do
                 :ok -> {:cont, :ok}
                 {:error, reason} -> {:halt, {:error, reason}}
               end
             end) do
        link_service_monitors(scope, service, MapSet.to_list(desired))
      end
    end
  end

  defp component_ids_for_monitor(scope, page_id, monitor_id) do
    links_query =
      Ash.Query.for_read(StatusComponentMonitor, :for_monitor, %{monitor_id: monitor_id},
        actor: scope
      )

    components_query =
      Ash.Query.for_read(StatusComponent, :for_page, %{status_page_id: page_id}, actor: scope)

    with {:ok, links} <- Ash.read(links_query, actor: scope),
         {:ok, components} <- Ash.read(components_query, actor: scope) do
      linked_ids = MapSet.new(links, & &1.status_component_id)

      {:ok,
       components
       |> Enum.map(& &1.id)
       |> Enum.filter(&MapSet.member?(linked_ids, &1))}
    end
  end

  defp service_monitor_ids(scope, service_id) do
    query =
      Ash.Query.for_read(
        StatusComponentMonitor,
        :for_component,
        %{status_component_id: service_id},
        actor: scope
      )

    with {:ok, links} <- Ash.read(query, actor: scope) do
      {:ok, links |> Enum.map(& &1.monitor_id) |> Enum.sort()}
    end
  end

  defp service_has_open_incident?(scope, service_id) do
    Queries.component_has_open_incident?(scope, service_id)
  end

  defp monitor_has_open_incident?(scope, page_id, monitor_id) do
    Queries.monitor_has_open_incident?(scope, page_id, monitor_id)
  end

  defp validate_incident_services(scope, page, service_ids) do
    Queries.validate_incident_services(scope, page, service_ids)
  end

  defp normalize_incident_service_states(states, service_ids) when is_map(states) do
    Enum.reduce_while(service_ids, {:ok, %{}}, fn service_id, {:ok, normalized} ->
      state = Map.get(states, service_id, Map.get(states, to_string(service_id), "outage"))
      state = if is_atom(state), do: Atom.to_string(state), else: state

      if state in @incident_service_states do
        {:cont, {:ok, Map.put(normalized, service_id, state)}}
      else
        {:halt, {:error, :invalid_incident_service_state}}
      end
    end)
  end

  defp normalize_incident_service_states(_states, _service_ids),
    do: {:error, :invalid_incident_service_state}

  defp link_incident_services(scope, incident, service_ids, service_states) do
    Queries.link_incident_services(scope, incident, service_ids, service_states)
  end

  defp read_incidents(scope, action, page_id) do
    StatusIncident
    |> Ash.Query.for_read(action, %{status_page_id: page_id}, actor: scope)
    |> Ash.Query.sort(published_at: :desc, id: :desc)
    |> Ash.Query.limit(@max_incidents)
    |> Ash.read(actor: scope)
    |> case do
      {:ok, %{results: incidents}} -> {:ok, incidents}
      {:ok, incidents} when is_list(incidents) -> {:ok, incidents}
      {:error, _} = error -> error
    end
  end

  defp scoped_incident(scope, incident) do
    case Ash.get(StatusIncident, component_id(incident), actor: scope) do
      {:ok, incident}
      when incident.org_id == scope.org_id and incident.project_id == scope.project_id ->
        {:ok, incident}

      _ ->
        {:error, :not_found}
    end
  end

  defp read_incident(scope, incident_or_id, manager?) do
    action = if(manager?, do: :operator_for_id, else: :for_id)
    incident_id = component_id(incident_or_id)

    StatusIncident
    |> Ash.Query.for_read(action, %{incident_id: incident_id}, actor: scope)
    |> Ash.read_one(actor: scope)
    |> case do
      {:ok, %StatusIncident{} = incident} -> {:ok, incident}
      {:ok, nil} -> {:error, :not_found}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp manager?(scope), do: Queries.manager?(scope)

  defp attach_incident_services(scope, incidents) do
    incident_ids = Enum.map(incidents, & &1.id)
    services = incident_services(scope, incident_ids)

    Enum.map(incidents, &Map.put(&1, :affected_services, Map.get(services, &1.id, [])))
  end

  defp incident_updates(scope, incident_id) do
    StatusIncidentUpdate
    |> Ash.Query.for_read(:read, %{}, actor: scope)
    |> Ash.Query.filter(
      org_id == ^scope.org_id and project_id == ^scope.project_id and
        status_incident_id == ^incident_id
    )
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(@max_updates)
    |> Ash.read(actor: scope)
    |> case do
      {:ok, %{results: updates}} -> {:ok, updates}
      {:ok, updates} when is_list(updates) -> {:ok, updates}
      {:error, _} = error -> error
    end
  end

  defp draft_for_incident(scope, incident_id) do
    case incident_draft(scope, incident_id) do
      {:ok, draft} -> draft
      _ -> nil
    end
  end

  defp detected_incident(_scope, nil), do: nil

  defp detected_incident(scope, incident_id) do
    Alplus.Monitoring.Incident
    |> Ash.Query.for_read(:read, %{}, actor: scope)
    |> Ash.Query.filter(
      id == ^incident_id and org_id == ^scope.org_id and project_id == ^scope.project_id
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(actor: scope)
    |> case do
      {:ok, incident} -> incident
      _ -> nil
    end
  end

  defp incident_services(scope, incident_id) when is_binary(incident_id) do
    incident_services(scope, [incident_id])
    |> Map.get(incident_id, [])
  end

  defp incident_services(scope, incident_ids) when is_list(incident_ids) do
    Queries.incident_services(scope, incident_ids, @max_incident_service_links)
  end

  defp scoped_announcement(scope, announcement) do
    case Ash.get(StatusAnnouncement, component_id(announcement), actor: scope) do
      {:ok, announcement}
      when announcement.org_id == scope.org_id and announcement.project_id == scope.project_id ->
        {:ok, announcement}

      _ ->
        {:error, :not_found}
    end
  end

  defp open_monitor_incident_id(scope, monitor_id) do
    Queries.open_monitor_incident_id(scope, monitor_id)
  end

  defp unhealthy_service_ids(scope, page_id) do
    Alplus.Status.Health.unhealthy_service_ids(scope, page_id)
  end

  defp maybe_update_next_target(_scope, incident, _next_update_at, false), do: {:ok, incident}

  defp maybe_update_next_target(scope, incident, next_update_at, true) do
    Ash.update(incident, %{next_update_at: next_update_at},
      action: :update_content,
      actor: scope
    )
  end

  defp resolve_incident_and_clear(scope, incident) do
    case with {:ok, incident} <- scoped_incident(scope, incident),
              do: Ash.update(incident, %{}, action: :resolve, actor: scope) do
      {:ok, _resolved} = result ->
        clear_status_cache()
        result

      other ->
        other
    end
  end

  defp reject_direct_resolution(attrs) do
    if attr(attrs, :stage) == "resolved",
      do: {:error, :resolution_update_required},
      else: :ok
  end

  defp ensure_stage_change_allowed(incident, attrs) do
    if attr_provided?(attrs, :stage), do: ensure_incident_open(incident), else: :ok
  end

  defp ensure_incident_open(%{status: "open"}), do: :ok
  defp ensure_incident_open(_incident), do: {:error, :incident_closed}

  defp attr_provided?(attrs, key) when is_map(attrs) do
    Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key))
  end

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value

  defp clear_status_cache, do: Alplus.Measure.PublicCache.clear()

  defp broadcast_monitor_update(project_id) do
    Phoenix.PubSub.broadcast(
      Alplus.PubSub,
      "monitor:#{project_id}",
      {:monitor_updated, project_id}
    )
  end

  defp component_id(%{id: id}), do: id
  defp component_id(id), do: id

  defp unwrap_page({:ok, %{results: results}}), do: {:ok, results}
  defp unwrap_page({:ok, results}) when is_list(results), do: {:ok, results}
  defp unwrap_page({:error, _} = error), do: error

  defdelegate resolve(slug), to: Alplus.Status.PublicPage
  defdelegate load_public(slug), to: Alplus.Status.PublicPage, as: :load
end
