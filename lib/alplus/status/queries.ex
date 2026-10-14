defmodule Alplus.Status.Queries do
  @moduledoc """
  Raw SQL access layer for Status.

  This module keeps only aggregate Status reads and the workspace advisory
  lock. Every query repeats the tenant predicate (`org_id`/`project_id`) on
  each tenant relation. `Alplus.Status` is the only caller.
  """

  alias Alplus.Repo

  @doc """
  Serializes first-run workspace setup across concurrent requests for one
  project. The transaction advisory lock closes the race between two
  first-run setup requests; the caller's transaction rollback prevents a
  failed workspace insert from leaving an orphan identity.
  """
  @spec lock_project!(String.t()) :: :ok
  def lock_project!(project_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [project_id])
    :ok
  end

  @doc "Returns every Status page that exposes `monitor_id`, org-wide (Oban worker path, no scope actor)."
  @spec pages_with_monitor(String.t(), String.t(), String.t()) :: [String.t()]
  def pages_with_monitor(org_id, project_id, monitor_id) do
    Repo.query!(
      """
      SELECT DISTINCT sc.status_page_id
      FROM status_components AS sc
      INNER JOIN status_component_monitors AS scm
        ON scm.status_component_id = sc.id
       AND scm.org_id = $1 AND scm.project_id = $2
      WHERE scm.monitor_id = $3
        AND sc.org_id = $1 AND sc.project_id = $2
      ORDER BY sc.status_page_id
      """,
      [org_id, project_id, monitor_id]
    ).rows
    |> List.flatten()
  end

  @doc "Returns whether one Monitor incident belongs to the supplied tenant and monitor."
  @spec monitor_incident_exists?(String.t(), String.t(), String.t(), String.t()) :: boolean()
  def monitor_incident_exists?(org_id, project_id, monitor_id, incident_id) do
    Repo.query!(
      """
      SELECT EXISTS(
        SELECT 1
        FROM incidents
        WHERE id = $1 AND org_id = $2 AND project_id = $3 AND monitor_id = $4
      )
      """,
      [incident_id, org_id, project_id, monitor_id]
    ).rows == [[true]]
  end

  @doc "Returns the monitor for one tenant-scoped persisted incident."
  @spec monitor_id_for_incident(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :not_found | term()}
  def monitor_id_for_incident(org_id, project_id, incident_id) do
    case Repo.query(
           "SELECT monitor_id FROM incidents WHERE id = $1 AND org_id = $2 AND project_id = $3",
           [incident_id, org_id, project_id]
         ) do
      {:ok, %{rows: [[monitor_id]]}} -> {:ok, monitor_id}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Serializes private draft creation for one Monitor incident and Status page."
  @spec lock_failure_draft!(String.t(), String.t(), String.t(), String.t()) :: :ok
  def lock_failure_draft!(org_id, project_id, page_id, incident_id) do
    Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtext($1))",
      [Enum.join([org_id, project_id, page_id, incident_id], ":")]
    )

    :ok
  end

  @doc "Returns the id of an already-open private draft for this monitor incident, if any."
  @spec open_private_incident_id(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def open_private_incident_id(org_id, project_id, page_id, incident_id) do
    case Repo.query(
           """
           SELECT id
           FROM status_incidents
           WHERE org_id = $1 AND project_id = $2 AND status_page_id = $3
             AND incident_id = $4 AND is_private = true AND status = 'open'
           LIMIT 1
           """,
           [org_id, project_id, page_id, incident_id]
         ) do
      {:ok, %{rows: [[id]]}} -> {:ok, id}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Component ids with an unhealthy linked monitor, computed entirely in SQL (unscoped Oban worker path)."
  @spec unhealthy_component_ids_unscoped(String.t(), String.t(), String.t()) :: [String.t()]
  def unhealthy_component_ids_unscoped(org_id, project_id, page_id) do
    Repo.query!(
      """
      SELECT DISTINCT sc.id
      FROM status_components AS sc
      INNER JOIN status_component_monitors AS scm
        ON scm.status_component_id = sc.id
       AND scm.org_id = $2 AND scm.project_id = $3
      INNER JOIN monitors AS m
        ON m.id = scm.monitor_id
       AND m.org_id = $2 AND m.project_id = $3
      WHERE sc.status_page_id = $1 AND sc.org_id = $2 AND sc.project_id = $3
        AND m.last_known_status IN ('down', 'degraded')
      ORDER BY sc.id
      """,
      [page_id, org_id, project_id]
    ).rows
    |> List.flatten()
  end

  @doc "Id of the service on this page already named `name`, case/space folded."
  @spec component_id_by_name(Alplus.Scope.t(), String.t(), String.t()) ::
          {:ok, String.t()} | :none
  def component_id_by_name(scope, status_page_id, name) when is_binary(name) do
    case Repo.query!(
           """
           SELECT id FROM status_components
            WHERE status_page_id = $1 AND org_id = $2 AND project_id = $3
              AND lower(btrim(name)) = $4
            LIMIT 1
           """,
           [
             status_page_id,
             scope.org_id,
             scope.project_id,
             name |> String.trim() |> String.downcase()
           ]
         ).rows do
      [[id]] -> {:ok, id}
      [] -> :none
    end
  end

  def component_id_by_name(_scope, _status_page_id, _name), do: :none

  @doc "Next free display position for a new service on this page."
  @spec next_component_position(Alplus.Scope.t(), String.t()) :: non_neg_integer()
  def next_component_position(scope, page_id) do
    [[position]] =
      Repo.query!(
        "SELECT COALESCE(MAX(position), -1) + 1 FROM status_components WHERE status_page_id = $1 AND org_id = $2 AND project_id = $3",
        [page_id, scope.org_id, scope.project_id]
      ).rows

    position
  end

  @doc "Count of monitors still linked to one service."
  @spec component_monitor_link_count(Alplus.Scope.t(), String.t()) :: non_neg_integer()
  def component_monitor_link_count(scope, component_id) do
    [[link_count]] =
      Repo.query!(
        "SELECT COUNT(*) FROM status_component_monitors WHERE status_component_id = $1 AND org_id = $2 AND project_id = $3",
        [component_id, scope.org_id, scope.project_id]
      ).rows

    link_count
  end

  @doc "Whether this page has at least one service backed by a real monitor."
  @spec component_exists_with_monitor?(Alplus.Scope.t(), String.t()) :: boolean()
  def component_exists_with_monitor?(scope, page_id) do
    case Repo.query(
           """
           SELECT 1
           FROM status_components AS sc
           INNER JOIN status_component_monitors AS scm
             ON scm.status_component_id = sc.id
            AND scm.org_id = $2
            AND scm.project_id = $3
           INNER JOIN monitors AS m
             ON m.id = scm.monitor_id
            AND m.org_id = $2
            AND m.project_id = $3
           WHERE sc.status_page_id = $1
             AND sc.org_id = $2
             AND sc.project_id = $3
           LIMIT 1
           """,
           [page_id, scope.org_id, scope.project_id]
         ) do
      {:ok, %{rows: [_ | _]}} -> true
      _ -> false
    end
  end

  @doc """
  Whether another service on this page already carries `name`.

  Compared with the same normalisation as the unique index
  (`status_components_page_name_index`): case folded, ends trimmed.
  """
  @spec service_name_taken?(Alplus.Scope.t(), String.t(), String.t() | nil, String.t() | nil) ::
          boolean()
  def service_name_taken?(scope, status_page_id, name, exclude_service_id \\ nil)

  def service_name_taken?(_scope, _status_page_id, name, _exclude) when not is_binary(name),
    do: false

  def service_name_taken?(scope, status_page_id, name, exclude_service_id) do
    normalized = name |> String.trim() |> String.downcase()

    if normalized == "" do
      false
    else
      [[count]] =
        Repo.query!(
          """
          SELECT COUNT(*) FROM status_components
           WHERE status_page_id = $1 AND org_id = $2 AND project_id = $3
             AND lower(btrim(name)) = $4
             AND ($5::text IS NULL OR id <> $5)
          """,
          [status_page_id, scope.org_id, scope.project_id, normalized, exclude_service_id]
        ).rows

      count > 0
    end
  end

  @doc "Whether one service has an open, public incident against it."
  @spec component_has_open_incident?(Alplus.Scope.t(), String.t()) :: boolean()
  def component_has_open_incident?(scope, service_id) do
    case Repo.query(
           """
           SELECT 1
           FROM status_incident_services AS sis
           INNER JOIN status_incidents AS si
             ON si.id = sis.status_incident_id
            AND si.org_id = $2
            AND si.project_id = $3
           WHERE sis.status_component_id = $1
             AND sis.org_id = $2
             AND sis.project_id = $3
             AND si.status = 'open'
             AND si.is_private = false
           LIMIT 1
           """,
           [service_id, scope.org_id, scope.project_id]
         ) do
      {:ok, %{rows: [_ | _]}} -> true
      _ -> false
    end
  end

  @doc "Whether one monitor, via any linked service on this page, has an open public incident."
  @spec monitor_has_open_incident?(Alplus.Scope.t(), String.t(), String.t()) :: boolean()
  def monitor_has_open_incident?(scope, page_id, monitor_id) do
    case Repo.query(
           """
           SELECT 1
           FROM status_components AS sc
           INNER JOIN status_component_monitors AS scm
             ON scm.status_component_id = sc.id
            AND scm.org_id = $2
            AND scm.project_id = $3
           INNER JOIN status_incident_services AS sis
             ON sis.status_component_id = sc.id
            AND sis.org_id = $2
            AND sis.project_id = $3
           INNER JOIN status_incidents AS si
             ON si.id = sis.status_incident_id
            AND si.org_id = $2
            AND si.project_id = $3
           WHERE sc.status_page_id = $1
             AND sc.org_id = $2
             AND sc.project_id = $3
             AND scm.monitor_id = $4
             AND si.status = 'open'
             AND si.is_private = false
           LIMIT 1
           """,
           [page_id, scope.org_id, scope.project_id, monitor_id]
         ) do
      {:ok, %{rows: [_ | _]}} -> true
      _ -> false
    end
  end

  @doc "Confirms every `service_ids` entry names a real service on this page."
  @spec validate_incident_services(Alplus.Scope.t(), map(), [String.t()]) ::
          :ok | {:error, :not_found}
  def validate_incident_services(_scope, _page, []), do: :ok

  def validate_incident_services(scope, page, service_ids) do
    rows =
      Repo.query!(
        """
        SELECT id
        FROM status_components
        WHERE status_page_id = $1 AND org_id = $2 AND project_id = $3
          AND id = ANY($4::text[])
        """,
        [page.id, scope.org_id, scope.project_id, service_ids]
      ).rows
      |> List.flatten()
      |> MapSet.new()

    if MapSet.size(rows) == length(service_ids), do: :ok, else: {:error, :not_found}
  end

  @doc "Links every `service_ids` entry to `incident` with its impact state. The join has no Ash resource."
  @spec link_incident_services(Alplus.Scope.t(), map(), [String.t()], map()) ::
          :ok | {:error, term()}
  def link_incident_services(scope, incident, service_ids, service_states) do
    Enum.reduce_while(service_ids, :ok, fn service_id, :ok ->
      state = Map.get(service_states, service_id, "outage")

      case Repo.query(
             """
             INSERT INTO status_incident_services
               (status_incident_id, status_component_id, org_id, project_id, state)
             VALUES ($1, $2, $3, $4, $5)
             ON CONFLICT (status_incident_id, status_component_id) DO NOTHING
             """,
             [incident.id, service_id, scope.org_id, scope.project_id, state]
           ) do
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc "Whether the scoped actor holds an owner or admin membership on this org."
  @spec manager?(Alplus.Scope.t()) :: boolean()
  def manager?(%Alplus.Scope{user_id: user_id, org_id: org_id})
      when is_binary(user_id) and is_binary(org_id) do
    case Repo.query(
           """
           SELECT 1
           FROM memberships
           WHERE user_id = $1 AND org_id = $2 AND role IN ('owner', 'admin')
           LIMIT 1
           """,
           [user_id, org_id]
         ) do
      {:ok, %{rows: [[1]]}} -> true
      _ -> false
    end
  end

  def manager?(_scope), do: false

  @doc "The affected services (with state and name) for one or more incidents, grouped by incident id."
  @spec incident_services(Alplus.Scope.t(), [String.t()], pos_integer()) :: %{
          String.t() => [map()]
        }
  def incident_services(_scope, [], _limit), do: %{}

  def incident_services(scope, incident_ids, limit) when is_list(incident_ids) do
    # The join table has no Ash resource. Keep this read bounded and repeat the
    # organization and project predicates on every relation in the query.
    Repo.query!(
      """
      SELECT sis.status_incident_id, sis.status_component_id, sis.state, sc.name
      FROM status_incident_services AS sis
      INNER JOIN status_components AS sc
        ON sc.id = sis.status_component_id
       AND sc.org_id = $2
       AND sc.project_id = $3
      WHERE sis.status_incident_id = ANY($1::text[])
        AND sis.org_id = $2
        AND sis.project_id = $3
      ORDER BY sis.status_component_id
      LIMIT $4
      """,
      [incident_ids, scope.org_id, scope.project_id, limit]
    ).rows
    |> Enum.group_by(fn [incident_id | _] -> incident_id end, fn [_, id, state, name] ->
      %{id: id, state: state, name: name}
    end)
  end

  @doc "The most recent open monitor-detected incident id, if any."
  @spec open_monitor_incident_id(Alplus.Scope.t(), String.t()) :: String.t() | nil
  def open_monitor_incident_id(scope, monitor_id) do
    case Repo.query(
           """
           SELECT id
           FROM incidents
           WHERE monitor_id = $1 AND org_id = $2 AND project_id = $3 AND status = 'open'
           ORDER BY started_at DESC
           LIMIT 1
           """,
           [monitor_id, scope.org_id, scope.project_id]
         ) do
      {:ok, %{rows: [[id]]}} -> id
      _ -> nil
    end
  end

  @doc "Newest published-incident-update timestamp for this page, coerced to UTC `DateTime`."
  @spec max_incident_update_at(Alplus.Scope.t(), String.t()) :: DateTime.t() | nil
  def max_incident_update_at(scope, page_id) do
    Repo.query!(
      "SELECT max(u.inserted_at) FROM status_incident_updates AS u INNER JOIN status_incidents AS si ON si.id = u.status_incident_id AND si.org_id = $1 AND si.project_id = $2 WHERE u.org_id = $1 AND u.project_id = $2 AND si.status_page_id = $3 AND si.published_at IS NOT NULL",
      [scope.org_id, scope.project_id, page_id]
    ).rows
    |> List.first()
    |> List.first()
    |> case do
      nil -> nil
      %DateTime{} = value -> value
      %NaiveDateTime{} = value -> DateTime.from_naive!(value, "Etc/UTC")
    end
  end

  @doc "Raw `[service_id, monitor_status, monitor_last_known_status]` rows for every service on this page."
  @spec monitor_health_rows(Alplus.Scope.t(), String.t()) :: [[String.t()]]
  def monitor_health_rows(scope, page_id) do
    Repo.query!(
      """
      SELECT DISTINCT sc.id, m.status, m.last_known_status
      FROM status_components AS sc
      INNER JOIN status_component_monitors AS scm
        ON scm.status_component_id = sc.id
       AND scm.org_id = $2 AND scm.project_id = $3
      INNER JOIN monitors AS m
        ON m.id = scm.monitor_id
       AND m.org_id = $2 AND m.project_id = $3
      WHERE sc.status_page_id = $1 AND sc.org_id = $2 AND sc.project_id = $3
      """,
      [page_id, scope.org_id, scope.project_id]
    ).rows
  end
end
