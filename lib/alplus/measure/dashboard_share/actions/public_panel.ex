defmodule Alplus.Measure.DashboardShare.Actions.PublicPanel do
  @moduledoc false

  use Ash.Resource.Actions.Implementation

  alias Alplus.Measure.Rollups

  @page_size 8
  @max_page 25

  @impl true
  def run(%{arguments: arguments}, _opts, %{actor: actor}) do
    %{dimension: dimension_atom, since: since, until: until, page: page} = arguments
    dimension = Atom.to_string(dimension_atom)
    {named_count, other_count, total_count, partial?} = meta(actor, dimension, since, until)
    capped? = other_count > 0
    distinct_values = named_count + if(capped?, do: 1, else: 0)
    total_pages = distinct_values |> ceil_div(@page_size) |> min(@max_page) |> max(1)

    page = page |> max(1) |> min(total_pages)
    rows = rows(actor, dimension, since, until, (page - 1) * @page_size, total_count)

    rows =
      if capped? and page == total_pages do
        rows ++
          [
            %{
              value: Rollups.other_value(),
              label: "(other) (per-day cardinality cap)",
              count: other_count,
              share: share(other_count, total_count),
              capped?: true
            }
          ]
      else
        rows
      end

    {:ok,
     %{
       rows: rows,
       page: page,
       total_pages: total_pages,
       distinct_values: distinct_values,
       capped?: capped?,
       partial?: partial?,
       cap_metadata:
         if capped? do
           %{value: Rollups.other_value(), reason: "per-day cardinality cap", position: :last}
         end,
       state: if(partial?, do: :partial, else: if(rows == [], do: :empty, else: :ready)),
       unavailable?: false,
       previous?: page > 1,
       next?: page < total_pages
     }}
  end

  defp meta(actor, dimension, since, until) do
    [[named_count, other_count, total_count, partial?]] =
      Alplus.Repo.query!(
        """
        WITH grouped AS (
          SELECT value,
                 SUM(CASE WHEN dimension IN ('path', 'event')
                          THEN pageviews ELSE COALESCE(visits, visitors) END)::bigint AS count,
                 bool_or(dimension NOT IN ('path', 'event') AND visits IS NULL) AS partial
          FROM analytics_dimensions
          WHERE org_id = $1 AND project_id = $2 AND source_id = $3 AND environment = $4
            AND dimension = $5 AND date BETWEEN $6 AND $7
          GROUP BY value
        )
        SELECT
          count(*) FILTER (WHERE value <> $8)::bigint,
          COALESCE(max(count) FILTER (WHERE value = $8), 0)::bigint,
          COALESCE(sum(count), 0)::bigint,
          COALESCE(bool_or(partial), false)
        FROM grouped
        """,
        [
          actor.org_id,
          actor.project_id,
          actor.source_id,
          actor.environment,
          dimension,
          since,
          until,
          Rollups.other_value()
        ]
      ).rows

    {named_count, other_count, total_count, partial?}
  end

  defp rows(actor, dimension, since, until, offset, total_count) do
    Alplus.Repo.query!(
      """
      SELECT value,
             SUM(CASE WHEN dimension IN ('path', 'event')
                      THEN pageviews ELSE COALESCE(visits, visitors) END)::bigint AS count
      FROM analytics_dimensions
      WHERE org_id = $1 AND project_id = $2 AND source_id = $3 AND environment = $4
        AND dimension = $5 AND date BETWEEN $6 AND $7 AND value <> $8
      GROUP BY value
      ORDER BY count DESC, value
      LIMIT $9 OFFSET $10
      """,
      [
        actor.org_id,
        actor.project_id,
        actor.source_id,
        actor.environment,
        dimension,
        since,
        until,
        Rollups.other_value(),
        @page_size,
        offset
      ]
    ).rows
    |> Enum.map(fn [value, count] ->
      %{
        value: value,
        label: value,
        count: count,
        share: share(count, total_count),
        capped?: false
      }
    end)
  end

  defp share(_count, 0), do: 0.0
  defp share(count, total), do: Float.round(count / total * 100, 1)

  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)
end
