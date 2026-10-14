defmodule Alplus.Observe.PublicEvidence do
  @moduledoc """
  Safe, bounded Observe evidence for the public marketing homepage.

  The homepage shows how many issues were active in a window and nothing
  else. No title, culprit, fingerprint, identifier, payload or event body
  ever leaves this module: every query returns counts only.
  """

  @doc """
  Counts issues active per hour or per day in one query.

  An issue counts in the bucket that holds its `last_seen_at`. Ash reads
  cannot express `GROUP BY date_trunc(...)` without loading every issue row,
  and a truthful count must not be capped by a read limit.
  """
  @spec load_issue_buckets(struct(), :hour | :day, DateTime.t()) :: [map()]
  # sobelow_skip ["SQL.Query"]
  def load_issue_buckets(actor, unit, since) when unit in [:hour, :day] do
    result =
      Alplus.Repo.query!(
        """
        SELECT date_trunc($4::text, last_seen_at) AS bucket, COUNT(*)::bigint AS issues
        FROM issues
        WHERE org_id = $1
          AND project_id = $2
          AND environment = 'production'
          AND last_seen_at >= $3
        GROUP BY 1
        ORDER BY 1
        """,
        [actor.org_id, actor.project_id, since, Atom.to_string(unit)]
      )

    Enum.map(result.rows, fn [bucket, issues] -> %{at: bucket, issues: issues} end)
  end
end
