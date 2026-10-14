defmodule Alplus.Seo.MaintenanceWorker do
  @moduledoc false
  use Oban.Worker, queue: :telemetry, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff = DateTime.add(DateTime.utc_now(), -7 * 24 * 60 * 60, :second)

    Alplus.Repo.query!(
      """
      SELECT p.id
      FROM seo_profiles AS p
      LEFT JOIN seo_snapshots AS s ON s.profile_id = p.id
      GROUP BY p.id
      HAVING max(s.captured_at) IS NULL OR max(s.captured_at) <= $1
      """,
      [cutoff]
    ).rows
    |> Enum.each(fn [profile_id] ->
      case Ash.get(Alplus.Seo.Profile, profile_id, authorize?: false) do
        {:ok, profile} -> Alplus.Seo.Refresher.queue(profile, :scheduled)
        _ -> :ok
      end
    end)

    Alplus.Seo.Retention.prune()

    :ok
  end
end
