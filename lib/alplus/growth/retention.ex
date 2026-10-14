defmodule Alplus.Growth.Retention do
  @moduledoc """
  Deletes health-check journey events after 30 days and keeps daily totals.

  Direct SQL: this is cross-tenant maintenance over two reporting tables, with
  no actor whose Ash policies could scope it. See
  `docs/DIRECT-ECTO-ESCAPE-HATCHES.md`.
  """

  alias Alplus.Repo

  @retention_days 30

  @spec prune(DateTime.t()) :: :ok
  def prune(%DateTime{} = now) do
    cutoff = DateTime.add(now, -@retention_days, :day)

    %{rows: rows} =
      Repo.query!(
        """
        SELECT (inserted_at AT TIME ZONE 'utc')::date, stage, count(*)
        FROM growth_journey_events
        WHERE inserted_at < $1
        GROUP BY 1, 2
        """,
        [cutoff]
      )

    Enum.each(rows, fn [day, stage, count] ->
      Repo.query!(
        """
        INSERT INTO growth_health_check_daily_counts (id, day, stage, count)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (day, stage)
        DO UPDATE SET count = growth_health_check_daily_counts.count + EXCLUDED.count
        """,
        [Alplus.Id.generate("gdc"), day, stage, count]
      )
    end)

    Repo.query!("DELETE FROM growth_journey_events WHERE inserted_at < $1", [cutoff])
    :ok
  end
end
