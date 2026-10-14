defmodule Alplus.Seo.Retention do
  @moduledoc "Prunes old SEO snapshots while retaining weekly and monthly history."

  def prune(now \\ DateTime.utc_now()) do
    weekly_cutoff = DateTime.add(now, -90 * 24 * 60 * 60, :second)
    monthly_cutoff = DateTime.add(now, -13 * 31 * 24 * 60 * 60, :second)

    Alplus.Repo.query!(
      """
      DELETE FROM seo_snapshots
      WHERE captured_at < $1
        AND id NOT IN (
          SELECT DISTINCT ON (profile_id, date_trunc('month', captured_at)) id
          FROM seo_snapshots
          WHERE captured_at >= $2
          ORDER BY profile_id, date_trunc('month', captured_at), captured_at DESC
        )
      """,
      [weekly_cutoff, monthly_cutoff]
    )

    :ok
  end
end
