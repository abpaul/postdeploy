defmodule Alplus.PublicPages.Migration do
  @moduledoc "Read-only preflight for the shared public-page contract."

  alias Alplus.Repo

  @doc "Reports the current shared public-page contract."
  def preflight(_opts \\ []), do: preflight_contract()


  defp preflight_contract do
    rows("""
    SELECT pp.project_id, pp.org_id, p.public_token, pp.public_slug, pp.title,
           pp.logo_url, pp.published_at, pp.inserted_at, count(sp.id)::integer
    FROM public_pages pp
    JOIN projects p ON p.id = pp.project_id
    LEFT JOIN status_pages sp ON sp.project_id = pp.project_id
    GROUP BY pp.project_id, pp.org_id, p.public_token, pp.public_slug,
             pp.title, pp.logo_url, pp.published_at, pp.inserted_at
    ORDER BY pp.project_id
    """)
    |> Enum.map(fn d ->
      %{
        project_id: d.project_id,
        org_id: d.org_id,
        public_token: d.public_token,
        surface: if(d.count > 0, do: :status, else: :changelog),
        source_slug: d.public_slug,
        public_slug: d.public_slug,
        title: d.title,
        logo_url: d.logo_url,
        source_rank: if(d.count > 0, do: 0, else: 2),
        source_at: d.inserted_at,
        published_at: d.published_at,
        status_page_count: d.count,
        multiple_status_pages: d.count > 1,
        alias_conflicts: [],
        decision: :reuse
      }
    end)
  end


  def report(opts \\ []) do
    decisions = preflight(opts)

    Enum.each(decisions, fn d ->
      Mix.shell().info(
        "project=#{d.project_id} surface=#{d.surface} source=#{d.source_slug} public=#{d.public_slug} decision=#{d.decision} statuses=#{d.status_page_count} alias_conflicts=#{length(d.alias_conflicts)}"
      )
    end)

    decisions
  end




  defp rows(sql) do
    result = Repo.query!(sql)

    Enum.map(result.rows, fn row ->
      result.columns |> Enum.zip(row) |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)
    end)
  end
end
