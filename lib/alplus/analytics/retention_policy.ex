defmodule Alplus.Analytics.RetentionPolicy do
  @moduledoc """
  Package-derived product-analytics retention (ADR 0007).

  The raw window IS the analysis window: funnels, retention, and unique-user
  counts all read raw events, so anything deleted here stops being
  answerable. `Alplus.Billing.Package` owns the number, and the console
  states it beside every date-range control.

  Bulk deletes are a documented direct PostgreSQL maintenance path
  (`docs/DIRECT-ECTO-ESCAPE-HATCHES.md`). Ash should not load historical
  event rows merely to delete them.
  """

  alias Alplus.Billing.Package
  alias Alplus.Repo

  @spec retention_days() :: pos_integer()
  def retention_days, do: Package.limit(:product_event_retention_days)

  @doc """
  Deletes events older than the retention window across every project, in
  bounded batches so one pass cannot hold a long write lock.

  Returns the number of event rows deleted.
  """
  @spec prune(Date.t(), keyword()) :: non_neg_integer()
  def prune(%Date{} = today, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 10_000)
    max_batches = Keyword.get(opts, :max_batches, 200)

    cutoff =
      today
      |> Date.add(-retention_days())
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    deleted = delete_batches(cutoff, batch_size, max_batches, 0)
    prune_property_keys(cutoff)
    deleted
  end

  defp delete_batches(_cutoff, _batch_size, 0, deleted), do: deleted

  defp delete_batches(cutoff, batch_size, batches_left, deleted) do
    %{num_rows: removed} =
      Repo.query!(
        """
        DELETE FROM product_events
        WHERE id IN (
          SELECT id FROM product_events WHERE occurred_at < $1 LIMIT $2
        )
        """,
        [cutoff, batch_size]
      )

    if removed < batch_size do
      deleted + removed
    else
      delete_batches(cutoff, batch_size, batches_left - 1, deleted + removed)
    end
  end

  # A property name nobody has sent inside the retention window can no longer
  # break down anything, so it leaves the picker too.
  defp prune_property_keys(cutoff) do
    Repo.query!("DELETE FROM product_event_property_keys WHERE last_seen_at < $1", [cutoff])
    :ok
  end
end
