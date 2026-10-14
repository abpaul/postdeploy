defmodule Alplus.Seo.Refresher do
  @moduledoc "Queues and executes bounded, budgeted SEO refreshes."

  require Ash.Query

  alias Alplus.Seo.{Collector, Competitor, Feature, Profile, Refresh}

  @monthly_budget_microusd 50_000_000
  @refresh_reservation_microusd 1_000_000

  def queue(profile, kind) when kind in [:initial, :scheduled, :manual] do
    if Feature.enabled?(profile.org_id) do
      month = Date.beginning_of_month(Date.utc_today())

      Alplus.Repo.transaction(fn ->
        lock_budget!(profile.org_id)

        if remaining_budget(profile.org_id, month) >= @refresh_reservation_microusd do
          refresh =
            Alplus.Seo.queue_refresh!(
              %{
                org_id: profile.org_id,
                project_id: profile.project_id,
                profile_id: profile.id,
                kind: kind,
                month: month,
                reserved_cost_microusd: @refresh_reservation_microusd
              },
              authorize?: false
            )

          {:ok, _job} =
            Alplus.Seo.RefreshWorker.new(%{"refresh_id" => refresh.id}) |> Oban.insert()

          refresh
        else
          Alplus.Repo.rollback(:monthly_budget_exhausted)
        end
      end)
    else
      {:error, :feature_disabled}
    end
  end

  def run(refresh_id) do
    with {:ok, refresh} <- get(Refresh, refresh_id),
         :queued <- refresh.status,
         {:ok, profile} <- get(Profile, refresh.profile_id),
         true <- Feature.enabled?(profile.org_id),
         {:ok, competitors} <- competitors(profile),
         refresh <- Alplus.Seo.start_refresh!(refresh, authorize?: false),
         {:ok, result} <- Collector.collect(profile, competitors),
         :ok <- save(profile, refresh, result) do
      :ok
    else
      :running -> :ok
      false -> finish_failure(refresh_id, "SEO access is disabled")
      {:error, reason} -> finish_failure(refresh_id, inspect(reason))
    end
  end

  defp save(profile, refresh, result) do
    competitors = Enum.map(result.competitors, &Map.drop(&1, [:response]))

    Alplus.Seo.create_snapshot!(
      %{
        org_id: profile.org_id,
        project_id: profile.project_id,
        profile_id: profile.id,
        refresh_id: refresh.id,
        captured_at: DateTime.utc_now(),
        overview: result.overview,
        keywords: result.keywords,
        pages: result.pages,
        competitors: competitors
      },
      authorize?: false
    )

    Alplus.Seo.succeed_refresh!(refresh, %{actual_cost_microusd: result.cost_microusd},
      authorize?: false
    )

    :ok
  rescue
    error -> {:error, error}
  end

  defp finish_failure(refresh_id, reason) do
    with {:ok, refresh} <- get(Refresh, refresh_id),
         :running <- refresh.status do
      Alplus.Seo.fail_refresh!(refresh, %{failure_reason: String.slice(reason, 0, 500)},
        authorize?: false
      )
    end

    :ok
  end

  defp competitors(profile) do
    {:ok,
     Competitor
     |> Ash.Query.filter(profile_id == ^profile.id)
     |> Ash.read!(authorize?: false)}
  end

  defp get(resource, id) do
    case Ash.get(resource, id, authorize?: false) do
      {:ok, row} -> {:ok, row}
      {:error, _} = error -> error
    end
  end

  defp lock_budget!(org_id),
    do: Alplus.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [org_id])

  defp remaining_budget(org_id, month) do
    %{rows: [[used]]} =
      Alplus.Repo.query!(
        "SELECT COALESCE(sum(actual_cost_microusd + CASE WHEN status IN ('queued', 'running') THEN reserved_cost_microusd ELSE 0 END), 0) FROM seo_refreshes WHERE org_id = $1 AND month = $2",
        [org_id, month]
      )

    @monthly_budget_microusd - used
  end
end
