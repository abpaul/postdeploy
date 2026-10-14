defmodule Alplus.PublicPages.Verification do
  @moduledoc "Read-only checks for the singleton public-page expand migration."

  alias Alplus.Repo

  @doc "Returns `:ok` or the findings that block the contract migration."
  @spec run(keyword()) :: :ok | {:error, [map()]}
  def run(_opts \\ []) do
    findings =
      duplicate_status_workspaces() ++
        missing_identities() ++
        duplicate_identity_projects() ++
        invalid_alias_targets() ++
        alias_slug_collisions() ++
        legacy_relationships()

    case findings do
      [] -> :ok
      findings -> {:error, findings}
    end
  end

  @doc "Raises when the singleton public-page checks do not pass."
  @spec verify!(keyword()) :: :ok
  def verify!(opts \\ []) do
    case run(opts) do
      :ok -> :ok
      {:error, findings} -> raise ArgumentError, format_findings(findings)
    end
  end

  @doc "Returns child rows that still point at a retired Status workspace."
  @spec relationship_counts(keyword()) :: [%{relation: String.t(), row_count: non_neg_integer()}]
  def relationship_counts(_opts \\ []) do
    Repo.query!("""
    WITH canonical AS (
      SELECT DISTINCT ON (project_id) project_id, id
      FROM status_pages
      ORDER BY project_id, inserted_at ASC, id ASC
    ), relationships AS (
      SELECT 'status_components' AS relation, sp.project_id
      FROM status_components AS child
      INNER JOIN status_pages AS sp ON sp.id = child.status_page_id
      INNER JOIN canonical AS keep ON keep.project_id = sp.project_id
      WHERE child.status_page_id <> keep.id
      UNION ALL
      SELECT 'status_component_monitors', sp.project_id
      FROM status_component_monitors AS child
      INNER JOIN status_components AS sc ON sc.id = child.status_component_id
      INNER JOIN status_pages AS sp ON sp.id = sc.status_page_id
      INNER JOIN canonical AS keep ON keep.project_id = sp.project_id
      WHERE sc.status_page_id <> keep.id
      UNION ALL
      SELECT 'status_incidents', sp.project_id
      FROM status_incidents AS child
      INNER JOIN status_pages AS sp ON sp.id = child.status_page_id
      INNER JOIN canonical AS keep ON keep.project_id = sp.project_id
      WHERE child.status_page_id <> keep.id
      UNION ALL
      SELECT 'status_incident_updates', sp.project_id
      FROM status_incident_updates AS child
      INNER JOIN status_incidents AS si ON si.id = child.status_incident_id
      INNER JOIN status_pages AS sp ON sp.id = si.status_page_id
      INNER JOIN canonical AS keep ON keep.project_id = sp.project_id
      WHERE si.status_page_id <> keep.id
      UNION ALL
      SELECT 'status_incident_services', sp.project_id
      FROM status_incident_services AS child
      INNER JOIN status_incidents AS si ON si.id = child.status_incident_id
      INNER JOIN status_pages AS sp ON sp.id = si.status_page_id
      INNER JOIN canonical AS keep ON keep.project_id = sp.project_id
      WHERE si.status_page_id <> keep.id
      UNION ALL
      SELECT 'status_scheduled_maintenances', sp.project_id
      FROM status_scheduled_maintenances AS child
      INNER JOIN status_pages AS sp ON sp.id = child.status_page_id
      INNER JOIN canonical AS keep ON keep.project_id = sp.project_id
      WHERE child.status_page_id <> keep.id
      UNION ALL
      SELECT 'status_announcements', sp.project_id
      FROM status_announcements AS child
      INNER JOIN status_pages AS sp ON sp.id = child.status_page_id
      INNER JOIN canonical AS keep ON keep.project_id = sp.project_id
      WHERE child.status_page_id <> keep.id
      UNION ALL
      SELECT 'status_incident_drafts', sp.project_id
      FROM status_incident_drafts AS child
      INNER JOIN status_pages AS sp ON sp.id = child.status_page_id
      INNER JOIN canonical AS keep ON keep.project_id = sp.project_id
      WHERE child.status_page_id <> keep.id
    )
    SELECT relation, count(*)::integer AS row_count
    FROM relationships
    GROUP BY relation
    ORDER BY relation
    """).rows
    |> Enum.map(fn [relation, row_count] -> %{relation: relation, row_count: row_count} end)
  end

  defp duplicate_status_workspaces do
    Repo.query!("""
    SELECT project_id, count(*)::integer AS page_count
    FROM status_pages
    GROUP BY project_id
    HAVING count(*) > 1
    ORDER BY project_id
    """).rows
    |> Enum.map(fn [project_id, page_count] ->
      %{check: :duplicate_status_workspaces, project_id: project_id, page_count: page_count}
    end)
  end

  defp missing_identities do
    Repo.query!("""
    SELECT p.id
    FROM projects AS p
    WHERE (
      EXISTS (SELECT 1 FROM status_pages AS sp WHERE sp.project_id = p.id)
      OR EXISTS (SELECT 1 FROM changelogs AS c WHERE c.project_id = p.id)
    )
    AND NOT EXISTS (SELECT 1 FROM public_pages AS pp WHERE pp.project_id = p.id)
    ORDER BY p.id
    """).rows
    |> Enum.map(fn [project_id] -> %{check: :missing_public_identity, project_id: project_id} end)
  end

  defp duplicate_identity_projects do
    Repo.query!("""
    SELECT project_id, count(*)::integer AS identity_count
    FROM public_pages
    GROUP BY project_id
    HAVING count(*) > 1
    ORDER BY project_id
    """).rows
    |> Enum.map(fn [project_id, identity_count] ->
      %{
        check: :duplicate_public_identities,
        project_id: project_id,
        identity_count: identity_count
      }
    end)
  end

  defp invalid_alias_targets do
    Repo.query!("""
    SELECT a.id
    FROM public_page_aliases AS a
    INNER JOIN public_pages AS pp ON pp.id = a.public_page_id
    WHERE a.org_id <> pp.org_id OR a.project_id <> pp.project_id
    ORDER BY a.id
    """).rows
    |> Enum.map(fn [alias_id] -> %{check: :invalid_alias_target, alias_id: alias_id} end)
  end

  defp alias_slug_collisions do
    Repo.query!("""
    SELECT a.public_slug, a.id
    FROM public_page_aliases AS a
    INNER JOIN public_pages AS pp ON pp.public_slug = a.public_slug
    ORDER BY a.public_slug, a.id
    """).rows
    |> Enum.map(fn [public_slug, alias_id] ->
      %{check: :alias_slug_collision, public_slug: public_slug, alias_id: alias_id}
    end)
  end

  defp legacy_relationships do
    relationship_counts()
    |> Enum.map(fn %{relation: relation, row_count: row_count} ->
      %{check: :legacy_relationships, relation: relation, row_count: row_count}
    end)
  end

  defp format_findings(findings) do
    "public-page verification failed: " <> inspect(findings, pretty: true)
  end
end
