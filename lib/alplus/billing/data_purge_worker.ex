defmodule Alplus.Billing.DataPurgeWorker do
  @moduledoc """
  Deletes stored product data for organizations whose access has been
  inactive for more than `Package.inactive_retention_days()` days past the lock date
  (issue #61, item 14).

  The lock date is the moment the organization lost access: `organizations.
  trial_ends_at` for an expired trial, the subscription's
  `current_period_end` for a lapsed subscription. Eligibility is confirmed
  through `Alplus.Billing.Access.check/1`, so this worker never purges an
  organization whose entitlement resolves successfully.

  Never delete: organizations, users, memberships, invitations, audit log,
  subscriptions, invoices, and Stripe webhook events. Billing history stays
  so operators can reconstruct what happened. Organization data deletes carry
  `org_id` in their WHERE clauses. The MCP idempotency prune is intentionally
  global because its seven-day retention applies across all organizations.

  Idempotent: a second run finds no rows and no payload keys, so it deletes
  nothing. Organizations are processed one at a time.
  """

  use Oban.Worker, queue: :billing, max_attempts: 3

  require Logger

  alias Alplus.Billing.{Access, EntitlementError, Package, StripeConfig}
  alias Alplus.Repo

  # Fixed, compile-time table list; never built from request data. Every
  # table has an `org_id` column. FKs cascade only from an organization
  # delete, which never happens here, so each delete is explicit.
  @measure_rollup_tables ~w(analytics_hours analytics_days analytics_dimensions goal_conversions)
  # Dependency order matters: child/history rows go before their parent rows.
  @monitor_history_tables ~w(incidents monitor_pause_intervals monitor_checks monitor_daily_rollups)
  @observe_history_tables ~w(issue_comments issue_user_reports error_events issues release_artifacts releases observe_session_rollups)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    # Prune MCP idempotency records before the billing gate. Their seven-day
    # retention has nothing to do with Stripe, so an unresolvable environment
    # must not silently stop it. This delete is global by design: the table is
    # keyed per organization but the retention window is not.
    :ok = prune_mcp_idempotency_records()
    :ok = Alplus.Mcp.OAuth.prune_expired()

    with {:ok, environment} <- StripeConfig.environment() do
      if environment in ["local", "production"] do
        cutoff =
          DateTime.utc_now()
          |> DateTime.add(-Package.inactive_retention_days(), :day)

        Enum.reduce_while(candidate_org_ids(), :ok, fn org_id, :ok ->
          case purge_if_locked_past(org_id, cutoff, environment) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
      else
        :ok
      end
    else
      {:error, _reason} = error -> error
    end
  end

  # Static SQL string; no external values are interpolated.
  # sobelow_skip ["SQL.Query"]
  defp prune_mcp_idempotency_records do
    cutoff = DateTime.add(DateTime.utc_now(), -7 * 24 * 60 * 60, :second)
    Repo.query!("DELETE FROM mcp_idempotency_records WHERE inserted_at < $1", [cutoff])
    :ok
  end

  # Inactive-access candidates only. The final eligibility decision goes
  # through Access.check/1 per organization, so this prefilter may be
  # broad but must not miss an eligible organization.
  # Static SQL string; no external values are interpolated.
  # sobelow_skip ["SQL.Query"]
  defp candidate_org_ids do
    Repo.query!("""
    SELECT id FROM organizations
    WHERE plan_status NOT IN ('active', 'past_due')
      AND NOT (
        plan_status = 'trialing'
        AND trial_ends_at > statement_timestamp()
      )
    """).rows
    |> List.flatten()
  end

  defp purge_if_locked_past(org_id, cutoff, environment) do
    case Repo.transaction(fn ->
           lock_organization(org_id)

           case Access.check(org_id) do
             {:ok, _access} ->
               :ok

             {:error, %EntitlementError{reason: :plan_inactive} = error} ->
               if locked_past?(org_id, error, cutoff, environment), do: purge(org_id), else: :ok

             {:error, %EntitlementError{}} ->
               :ok
           end
         end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  # Serialize purge eligibility and deletion with every billing transition.
  # Billing writes update the same organization row, so Access cannot become
  # active between the final decision and the scoped deletes.
  # sobelow_skip ["SQL.Query"]
  defp lock_organization(org_id) do
    Repo.query!("SELECT id FROM organizations WHERE id = $1 FOR UPDATE", [org_id])
  end

  # A raw query returns a NaiveDateTime for timestamp columns; coerce at the
  # boundary before any DateTime comparison.
  defp locked_past?(org_id, %EntitlementError{cause: cause}, cutoff, environment) do
    case lock_date(org_id, cause, environment) do
      %DateTime{} = lock_date ->
        DateTime.compare(lock_date, cutoff) == :lt

      nil ->
        Logger.warning(
          "data_purge: skipping org #{org_id}, no resolvable lock date for cause #{inspect(cause)}"
        )

        false
    end
  end

  defp lock_date(org_id, :trial_expired, _environment), do: org_trial_ends_at(org_id)

  defp lock_date(org_id, :subscription_lapsed, environment),
    do: latest_subscription_period_end(org_id, environment) || org_trial_ends_at(org_id)

  defp lock_date(_org_id, _cause, _environment), do: nil

  # sobelow_skip ["SQL.Query"]
  defp org_trial_ends_at(org_id) do
    case Repo.query!("SELECT trial_ends_at FROM organizations WHERE id = $1", [org_id]).rows do
      [[nil]] -> nil
      [[value]] -> to_utc(value)
      [] -> nil
    end
  end

  # sobelow_skip ["SQL.Query"]
  defp latest_subscription_period_end(org_id, environment) do
    case Repo.query!(
           "SELECT max(current_period_end) FROM subscriptions WHERE org_id = $1 AND stripe_environment = $2",
           [org_id, environment]
         ).rows do
      [[nil]] -> nil
      [[value]] -> to_utc(value)
      [] -> nil
    end
  end

  defp purge(org_id) do
    objects = external_object_deletes(org_id)

    rollups =
      Enum.map(
        @measure_rollup_tables ++ @monitor_history_tables ++ @observe_history_tables,
        fn table ->
          {table, delete_all_in_table(table, org_id)}
        end
      )

    # Insert the object jobs after deleting their references, within the same
    # transaction. Oban keeps the inserts invisible until this transaction
    # commits, so no worker can consume a reference before its deletion.
    objects_queued = enqueue_external_object_deletes(objects, org_id)

    Logger.info(
      "data_purge: org #{org_id} purged, " <>
        "objects_queued=#{objects_queued}, " <>
        Enum.map_join(rollups, ", ", fn {table, count} -> "#{table}=#{count}" end)
    )

    :ok
  end

  # Payload keys are collected before their referencing event rows vanish.
  # sobelow_skip ["SQL.Query"]
  defp external_object_deletes(org_id) do
    Repo.query!(
      """
      SELECT payload_s3_key, project_id, 'events' FROM error_events
      WHERE org_id = $1 AND payload_s3_key IS NOT NULL
      UNION ALL
      SELECT storage_key, project_id, 'artifacts' FROM release_artifacts WHERE org_id = $1
      """,
      [org_id]
    ).rows
  end

  defp enqueue_external_object_deletes(objects, org_id) do
    Enum.each(objects, fn [key, project_id, kind] ->
      %{key: key, kind: kind, org_id: org_id, project_id: project_id}
      |> Alplus.Billing.DataPurgeObjectWorker.new()
      |> Oban.insert!()
    end)

    length(objects)
  end

  # `table` comes only from the compile-time lists above, never from data.
  # sobelow_skip ["SQL.Query"]
  defp delete_all_in_table(table, org_id) do
    Repo.query!("DELETE FROM #{table} WHERE org_id = $1", [org_id]).num_rows
  end

  defp to_utc(%DateTime{} = value), do: value
  defp to_utc(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
end
