defmodule Alplus.Billing.UsageRollover do
  @moduledoc """
  Creates the current UTC usage period for every organization.

  Ingest also creates a period on demand. This daily job makes a month change
  visible before the first event arrives and is safe to retry.
  """

  alias Alplus.{Id, Repo}

  @spec rollover(Date.t()) :: non_neg_integer()
  def rollover(%Date{} = date) do
    period_start = Date.beginning_of_month(date)

    Repo.transaction(fn ->
      Repo.query!("SELECT id FROM organizations").rows
      |> Enum.count(fn [org_id] ->
        %{num_rows: count} =
          Repo.query!(
            """
            INSERT INTO usage_periods (id, org_id, period_start, inserted_at, updated_at)
            VALUES ($1, $2, $3, now(), now())
            ON CONFLICT (org_id, period_start) DO NOTHING
            """,
            [Id.generate(:usage_period), org_id, period_start]
          )

        count == 1
      end)
    end)
    |> elem(1)
  end
end
