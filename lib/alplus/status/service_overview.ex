defmodule Alplus.Status.ServiceOverview do
  @moduledoc """
  Project-scoped read model for authenticated Status services.

  Monitor owns observation. Status owns the customer-facing grouping and
  incident override. This module joins those two sources for one bounded page
  read and adds reliability only when one monitor gives the service an
  unambiguous objective.
  """

  alias Alplus.Monitoring.{Monitor, Reliability}
  alias Alplus.Repo
  alias Alplus.Scope

  alias Alplus.Status.{PublicPage, StatusComponent, StatusPage}

  require Ash.Query

  @max_services 100
  @max_links 5_000

  @typedoc "A customer-facing service with scoped Monitor observations."
  @type service :: %{
          id: String.t(),
          name: String.t(),
          description: String.t() | nil,
          position: non_neg_integer(),
          monitor_ids: [String.t()],
          monitors: [Monitor.t()],
          state: :operational | :degraded | :down | :maintenance,
          reliability: map() | nil
        }

  @doc "Loads all services for a scoped Status workspace."
  @spec list(Scope.t(), StatusPage.t() | String.t(), keyword()) ::
          {:ok, [service()]} | {:error, term()}
  def list(%Scope{} = scope, page_or_id, options \\ []) when is_list(options) do
    include_reliability? = Keyword.get(options, :reliability?, false)

    with {:ok, page} <- scoped_page(scope, page_or_id),
         {:ok, components} <- components(scope, page.id),
         links <- monitor_links(scope, page.id, Enum.map(components, & &1.id)),
         monitors <- monitors(scope, links),
         reliability <-
           reliability_by_monitor(monitors, scope, include_reliability?),
         maintenance_ids <- active_maintenance_monitor_ids(scope, page.id),
         incident_overrides <- active_incident_overrides(scope, page.id) do
      services =
        Enum.map(components, fn component ->
          build_service(
            component,
            Map.get(links, component.id, []),
            monitors,
            maintenance_ids,
            incident_overrides,
            reliability
          )
        end)

      {:ok, services}
    end
  end

  @doc "Loads one service only when it belongs to the scoped Status workspace."
  @spec get(Scope.t(), StatusPage.t() | String.t(), String.t(), keyword()) ::
          {:ok, service()} | {:error, :not_found | term()}
  def get(%Scope{} = scope, page_or_id, service_id, options \\ [])
      when is_binary(service_id) and is_list(options) do
    with {:ok, page} <- scoped_page(scope, page_or_id),
         {:ok, component} <- component(scope, service_id),
         true <- component.status_page_id == page.id do
      case list(scope, page, options) do
        {:ok, services} ->
          case Enum.find(services, &(&1.id == component.id)) do
            nil -> {:error, :not_found}
            service -> {:ok, service}
          end

        other ->
          other
      end
    else
      false -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp scoped_page(scope, %{id: id}), do: scoped_page(scope, id)

  defp scoped_page(%Scope{} = scope, page_id) when is_binary(page_id) do
    query =
      StatusPage
      |> Ash.Query.for_read(:read, %{}, actor: scope)
      |> Ash.Query.filter(
        id == ^page_id and org_id == ^scope.org_id and project_id == ^scope.project_id
      )

    case Ash.read_one(query) do
      {:ok, %StatusPage{} = page} -> {:ok, page}
      {:ok, nil} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp scoped_page(_scope, _page_id), do: {:error, :not_found}

  defp components(scope, page_id) do
    query =
      StatusComponent
      |> Ash.Query.for_read(:for_page, %{status_page_id: page_id}, actor: scope)
      |> Ash.Query.sort(position: :asc, id: :asc)
      |> Ash.Query.limit(@max_services)

    case Ash.read(query) do
      {:ok, %{results: results}} -> {:ok, results}
      {:ok, results} when is_list(results) -> {:ok, results}
      {:error, _} = error -> error
    end
  end

  defp component(scope, service_id) do
    query =
      StatusComponent
      |> Ash.Query.for_read(:read, %{}, actor: scope)
      |> Ash.Query.filter(
        id == ^service_id and org_id == ^scope.org_id and project_id == ^scope.project_id
      )

    case Ash.read_one(query) do
      {:ok, %StatusComponent{} = component} -> {:ok, component}
      {:ok, nil} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp monitor_links(_scope, _page_id, []), do: %{}

  defp monitor_links(scope, page_id, component_ids) do
    # The join table has no Ash resource. Keep this bounded escape hatch
    # tenant-scoped and cap the total links returned to the page read model.
    Repo.query!(
      """
      SELECT scm.status_component_id, scm.monitor_id
      FROM status_component_monitors AS scm
      INNER JOIN status_components AS sc
        ON sc.id = scm.status_component_id
       AND sc.org_id = $1
       AND sc.project_id = $2
       AND sc.status_page_id = $3
      WHERE scm.org_id = $1
        AND scm.project_id = $2
        AND scm.status_component_id = ANY($4::text[])
      ORDER BY scm.status_component_id, scm.monitor_id
      LIMIT $5
      """,
      [scope.org_id, scope.project_id, page_id, component_ids, @max_links]
    ).rows
    |> Enum.group_by(&Enum.at(&1, 0), &Enum.at(&1, 1))
  end

  defp monitors(_scope, links) when map_size(links) == 0, do: %{}

  defp monitors(scope, links) do
    ids = links |> Map.values() |> List.flatten() |> Enum.uniq()

    Monitor
    |> Ash.Query.for_read(:list_for_project, %{project_id: scope.project_id}, actor: scope)
    |> Ash.Query.filter(
      org_id == ^scope.org_id and project_id == ^scope.project_id and id in ^ids
    )
    |> Ash.Query.limit(@max_links)
    |> Ash.read!(actor: scope)
    |> Map.new(&{&1.id, &1})
  end

  defp build_service(
         component,
         monitor_ids,
         monitors,
         maintenance_ids,
         incident_overrides,
         reliability_by_monitor
       ) do
    linked_monitors =
      monitor_ids
      |> Enum.map(&Map.get(monitors, &1))
      |> Enum.reject(&is_nil/1)

    state =
      case Map.get(incident_overrides, component.id) do
        :up -> :operational
        nil -> service_state(linked_monitors, maintenance_ids, monitor_ids)
        state -> state
      end

    %{
      id: component.id,
      name: component.name,
      description: component.description,
      position: component.position,
      monitor_ids: monitor_ids,
      monitors: linked_monitors,
      state: state,
      reliability:
        if(length(linked_monitors) == 1,
          do: reliability(linked_monitors, reliability_by_monitor),
          else: nil
        )
    }
  end

  defp service_state(monitors, maintenance_ids, monitor_ids) do
    maintenance? = Enum.any?(monitor_ids, &MapSet.member?(maintenance_ids, &1))

    case PublicPage.service_status(monitors, maintenance?) do
      :up -> :operational
      state -> state
    end
  end

  defp reliability([%{slo_target: target} = monitor], reliability_by_monitor)
       when is_number(target) and target > 0 and target <= 1 do
    Map.get(reliability_by_monitor, monitor.id, %{
      state: :error,
      target: target,
      error: :not_found
    })
  end

  # A target on one member of a multi-monitor service cannot describe the
  # service. Keep SLO output absent until a supported mapping exists.
  defp reliability(_monitors, _reliability_by_monitor), do: nil

  defp reliability_by_monitor(_monitors, _scope, false), do: %{}

  defp reliability_by_monitor(monitors, scope, true) do
    eligible =
      monitors
      |> Map.values()
      |> Enum.filter(fn monitor ->
        is_number(monitor.slo_target) and monitor.slo_target > 0 and monitor.slo_target <= 1
      end)

    case Reliability.histories(eligible, scope) do
      {:ok, histories} ->
        histories

      {:error, reason} ->
        Map.new(eligible, &{&1.id, %{state: :error, target: &1.slo_target, error: reason}})
    end
  end

  defp active_maintenance_monitor_ids(scope, page_id) do
    now = DateTime.utc_now()

    Repo.query!(
      """
      SELECT DISTINCT mm.monitor_id
      FROM status_maintenance_monitors AS mm
      INNER JOIN status_scheduled_maintenances AS m
        ON m.id = mm.maintenance_id
       AND m.org_id = $1
       AND m.project_id = $2
      WHERE mm.org_id = $1
        AND mm.project_id = $2
        AND m.status_page_id = $3
        AND m.status IN ('scheduled', 'active')
        AND m.starts_at <= $4
        AND m.ends_at > $4
      LIMIT $5
      """,
      [scope.org_id, scope.project_id, page_id, now, @max_links]
    ).rows
    |> MapSet.new(fn [monitor_id] -> monitor_id end)
  end

  defp active_incident_overrides(scope, page_id) do
    Repo.query!(
      """
      SELECT sis.status_component_id, sis.state
      FROM status_incident_services AS sis
      INNER JOIN status_incidents AS si
        ON si.id = sis.status_incident_id
       AND si.org_id = $1
       AND si.project_id = $2
      WHERE sis.org_id = $1
        AND sis.project_id = $2
        AND si.status_page_id = $3
        AND si.status = 'open'
        AND si.is_private = false
      ORDER BY si.published_at DESC
      LIMIT $4
      """,
      [scope.org_id, scope.project_id, page_id, @max_links]
    ).rows
    |> PublicPage.reduce_incident_overrides()
  end
end
