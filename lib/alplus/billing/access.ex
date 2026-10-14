defmodule Alplus.Billing.Access do
  @moduledoc """
  One interface for every package-aware decision (issue #54).

  Every gate answers "may this organization do X" from an org id alone:
  this module resolves whether the organization is in its trial, subscribed,
  or inactive, so no caller resolves access before checking a gate. Every
  entitlement failure returns the one `Alplus.Billing.EntitlementError` shape.

  The trial and the subscription grant the same `Alplus.Billing.Package`
  limits. The access state decides only whether the organization may write.

  This is a direct PostgreSQL read because it is a small, aggregate
  capacity query at a write boundary. Ash owns the created resources
  themselves.
  """

  alias Alplus.Billing.{EntitlementError, Package, StripeConfig}
  alias Alplus.Repo

  @type state :: :trial | :subscribed

  @uptime_types ~w(http keyword tcp dns)
  @cron_types ~w(heartbeat)

  @capacity_metrics %{
    projects: {"projects", "archived_at IS NULL"}
  }

  @type capacity_metric :: :projects

  # The newest mirrored subscription for the configured Stripe environment.
  # `plan_status` is the column behind `Organization`'s `billing_status`
  # attribute; the contract migration renames it.
  @access_select """
  SELECT o.plan_status, o.trial_ends_at, s.status, s.current_period_end,
         EXISTS (SELECT 1 FROM subscriptions WHERE org_id = o.id) AS subscribed_before
  FROM organizations o
  LEFT JOIN LATERAL (
    SELECT status, current_period_end
    FROM subscriptions
    WHERE org_id = o.id AND stripe_environment = $2
    ORDER BY current_period_end DESC NULLS LAST
    LIMIT 1
  ) s ON TRUE
  """

  @doc """
  Resolves the organization's access state. The single resolution point
  behind every gate here.

  Resolution table (issue #61): an `active` or `past_due` subscription
  resolves to `:subscribed`; a `trialing` organization inside its trial
  window resolves to `:trial`; everything else is
  `{:error, %EntitlementError{reason: :plan_inactive}}` with the cause and
  the data-purge date.
  """
  @spec check(String.t()) :: {:ok, state()} | {:error, EntitlementError.t()}
  # Fully parameterized ($1, $2); the SQL string is a fixed compile-time literal.
  # sobelow_skip ["SQL.Query"]
  def check(org_id) when is_binary(org_id) do
    with {:ok, environment} <- configured_environment() do
      rows = Repo.query!(@access_select <> "WHERE o.id = $1", [org_id, environment]).rows
      resolve_rows(rows, org_id, environment)
    end
  end

  @doc """
  Resolves several organizations with the same decision table as `check/1`.

  This is the scheduler's batch read. It avoids one entitlement query per
  organization during periodic monitor reconciliation.
  """
  @spec check_many([String.t()]) :: %{
          String.t() => {:ok, state()} | {:error, EntitlementError.t()}
        }
  def check_many([]), do: %{}

  # sobelow_skip ["SQL.Query"]
  def check_many(org_ids) when is_list(org_ids) do
    with {:ok, environment} <- configured_environment() do
      rows =
        Repo.query!(
          String.replace(
            @access_select,
            "SELECT o.plan_status",
            "SELECT o.id, o.plan_status"
          ) <>
            "WHERE o.id = ANY($1::text[])",
          [org_ids, environment]
        ).rows

      Map.new(rows, fn [org_id | row] ->
        {org_id, resolve_rows([row], org_id, environment)}
      end)
    else
      {:error, %EntitlementError{} = error} -> Map.new(org_ids, &{&1, {:error, error}})
    end
  end

  @doc """
  Allows creating one more of `metric` when the package still has
  a free slot. Runs inside the caller's Ash create transaction, where the
  locked organization row serializes concurrent creates.

  Seats are not a `metric`: a seat is a membership OR a pending invitation,
  so `allow_seat/2` counts both.
  """
  @spec allow_create(String.t(), capacity_metric()) ::
          :ok | {:error, EntitlementError.t()}
  def allow_create(org_id, metric)
      when is_binary(org_id) and is_map_key(@capacity_metrics, metric) do
    with {:ok, _state} <- lock_access(org_id) do
      check_capacity(org_id, metric, count_capacity(org_id, metric), :capacity_reached)
    end
  end

  @doc """
  Whether this organization may take one more seat.

  A seat is a membership OR a pending, unexpired invitation. Both count, at
  every point a seat is taken: sending an invitation, adding a member
  directly, and accepting an invitation. Counting only memberships produced
  the same dead end twice — an invitation was created and emailed, then the
  recipient hit "Could not accept that invitation." with no way to act on it,
  either because the invite never reserved its seat or because a direct add
  took the seat away afterwards.

  `:except_invitation_id` names the invitation being accepted right now. Its
  reservation must not count against the membership it becomes: the row is
  still `pending` when that membership is created, inside the same
  transaction.
  """
  @spec allow_seat(String.t(), keyword()) :: :ok | {:error, EntitlementError.t()}
  def allow_seat(org_id, opts \\ []) when is_binary(org_id) and is_list(opts) do
    except_invitation_id = Keyword.get(opts, :except_invitation_id)

    with {:ok, _state} <- lock_access(org_id) do
      taken = count_seats(org_id, except_invitation_id)
      limit = Package.limit(:members)

      if taken < limit do
        :ok
      else
        {:error,
         %EntitlementError{
           code: :capacity_reached,
           message:
             "PostDeploy includes #{limit} #{if limit == 1, do: "member", else: "members"}, " <>
               "and all seats are taken by members or pending invitations. " <>
               "Remove a member or a pending invitation to invite someone new.",
           details: %{
             org_id: org_id,
             metric: :members,
             current: taken,
             limit: limit
           }
         }}
      end
    end
  end

  @doc """
  Allows a new monitor only when its type, interval, retry interval, and
  organisation-wide capacity are permitted by the package.

  Required options are `:project_id`, `:type`, and `:interval_seconds`.
  `:retry_interval_seconds` is optional, but follows the same interval floor
  when present.
  """
  @spec allow_monitor_create(String.t(), map()) ::
          {:ok, %{current: non_neg_integer(), limit: pos_integer()}}
          | {:error, EntitlementError.t()}
  def allow_monitor_create(org_id, %{type: type} = options) when is_binary(org_id) do
    with {:ok, _state} <- lock_access(org_id),
         {:ok, metric} <- metric_for_type(type),
         :ok <- validate_ids(org_id, Map.get(options, :project_id)),
         :ok <- check_interval(Map.get(options, :interval_seconds), :interval_seconds),
         :ok <- check_retry_interval(Map.get(options, :retry_interval_seconds)),
         {:ok, current} <-
           current_monitor_count(org_id, Map.fetch!(options, :project_id), metric) do
      check_capacity_ok(metric, current)
    else
      {:error, %EntitlementError{}} = error -> error
    end
  end

  @doc """
  Allows a monitor row when its type-specific organization capacity has room.

  The Monitor resource uses this gate because its public create action does
  not receive the typed configuration interval. `MonitorCreator` performs the
  additional interval checks before it creates that configuration.
  """
  @spec allow_monitor_capacity(String.t(), String.t(), String.t()) ::
          {:ok, %{current: non_neg_integer(), limit: pos_integer()}}
          | {:error, EntitlementError.t()}
  def allow_monitor_capacity(org_id, project_id, type)
      when is_binary(org_id) and is_binary(project_id) and is_binary(type) do
    with {:ok, _state} <- lock_access(org_id),
         {:ok, metric} <- metric_for_type(type),
         :ok <- validate_ids(org_id, project_id),
         {:ok, current} <- current_monitor_count(org_id, project_id, metric) do
      check_capacity_ok(metric, current)
    else
      {:error, %EntitlementError{}} = error -> error
    end
  end

  @doc """
  Allows an interval change on an existing monitor. Unlike
  `allow_monitor_create/2`, this never checks capacity — the monitor
  already counts against it — so only the interval (and retry interval,
  when present) is checked against the package's interval floor.

  Required option is `:interval_seconds`.
  """
  @spec allow_monitor_update(String.t(), map()) :: :ok | {:error, EntitlementError.t()}
  def allow_monitor_update(org_id, options) when is_binary(org_id) and is_map(options) do
    with {:ok, _state} <- check(org_id),
         :ok <- check_interval(Map.get(options, :interval_seconds), :interval_seconds) do
      check_retry_interval(Map.get(options, :retry_interval_seconds))
    end
  end

  @doc """
  Allows a heartbeat or cron monitor after its explicit capacity check.
  Required option is `:project_id`.
  """
  @spec allow_heartbeat_create(String.t(), map()) ::
          {:ok, %{current: non_neg_integer(), limit: pos_integer()}}
          | {:error, EntitlementError.t()}
  def allow_heartbeat_create(org_id, options) when is_binary(org_id) and is_map(options) do
    with {:ok, _state} <- lock_access(org_id),
         :ok <- validate_ids(org_id, Map.get(options, :project_id)),
         {:ok, current} <-
           current_monitor_count(org_id, Map.fetch!(options, :project_id), :cron_jobs) do
      check_capacity_ok(:cron_jobs, current)
    else
      {:error, %EntitlementError{}} = error -> error
    end
  end

  @doc """
  Allows a notification channel type while the organization has access.
  The package includes every channel type.
  """
  @spec allow_notification_channel(String.t(), String.t()) :: :ok | {:error, EntitlementError.t()}
  def allow_notification_channel(org_id, channel_type) when is_binary(org_id) do
    with {:ok, _state} <- check(org_id) do
      known_channel_type(channel_type)
    end
  end

  @doc """
  Returns the organisation-wide monitor count only when `project_id` belongs
  to `org_id`. A missing or cross-tenant project receives the same not-found
  result and never exposes another organisation's count.
  """
  @spec current_monitor_count(String.t(), String.t(), :uptime_monitors | :cron_jobs) ::
          {:ok, non_neg_integer()} | {:error, EntitlementError.t()}
  # `type_filter` comes from `type_filter/1` below, a private function with
  # one fixed clause per `metric` atom value — never from request data. The
  # query itself is parameterized ($1, $2) for org_id/project_id.
  # sobelow_skip ["SQL.Query"]
  def current_monitor_count(org_id, project_id, metric)
      when is_binary(org_id) and is_binary(project_id) do
    type_filter = type_filter(metric)

    result =
      Repo.query!(
        """
        SELECT count(monitors.id)
        FROM projects
        LEFT JOIN monitors ON monitors.org_id = projects.org_id AND #{type_filter}
        WHERE projects.org_id = $1 AND projects.id = $2
        GROUP BY projects.id
        """,
        [org_id, project_id]
      )

    case result.rows do
      [[count]] ->
        {:ok, count}

      [] ->
        {:error,
         error(:project_not_found, "The project was not found.", %{
           org_id: org_id,
           project_id: project_id
         })}
    end
  end

  def current_monitor_count(org_id, project_id, _metric) do
    {:error,
     error(:invalid_scope, "An organisation id and project id are required.", %{
       org_id: org_id,
       project_id: project_id
     })}
  end

  # Takes the organization row lock and resolves access from the LOCKED
  # row, through the same resolution table as `check/1`. Two separate
  # commands, never one: under READ COMMITTED a single command that both
  # waits on `FOR UPDATE` and counts keeps the snapshot it took before the
  # wait, so the winner's insert stays invisible and two concurrent
  # last-slot creates both succeed. The count below is a SECOND command,
  # planned after the lock is held, so it sees the winner.
  #
  # Reading access from the locked row also closes the lapse race: access
  # resolved before the lock can be stale by the time the decision is made.
  #
  # Callers run this from an Ash `before_action` or an explicit transaction,
  # so the lock is held until the create commits.
  # Fully parameterized ($1, $2); the SQL string is a fixed compile-time literal.
  # sobelow_skip ["SQL.Query"]
  defp lock_access(org_id) do
    with {:ok, environment} <- configured_environment() do
      rows =
        Repo.query!(@access_select <> "WHERE o.id = $1\nFOR UPDATE OF o", [
          org_id,
          environment
        ]).rows

      resolve_rows(rows, org_id, environment)
    end
  end

  # The one resolution table (issue #61). Branch order matters: an active
  # subscription wins first, then an in-window trial, then refusal.
  defp resolve_rows(
         [[org_status, trial_ends_at, subscription_status, period_end, subscribed_before]],
         org_id,
         environment
       ) do
    cond do
      subscription_status in ["active", "past_due"] ->
        {:ok, :subscribed}

      not is_nil(subscription_status) ->
        inactive(org_id, :subscription_lapsed, subscription_status, trial_ends_at, period_end)

      environment in ["local", "production"] and org_status in ["active", "past_due"] ->
        {:ok, :subscribed}

      org_status == "trialing" and not subscribed_before and
          in_trial_window?(trial_ends_at) ->
        {:ok, :trial}

      org_status == "trialing" and not subscribed_before ->
        inactive(org_id, :trial_expired, org_status, trial_ends_at, nil)

      # `trialing` after a subscription has existed is Stripe's own trial on a
      # paid subscription, never a second free trial. Without a mirrored
      # subscription row for this environment there is nothing to grant.
      true ->
        inactive(org_id, :subscription_lapsed, org_status, trial_ends_at, nil)
    end
  end

  defp resolve_rows([], org_id, _environment),
    do:
      {:error,
       error(:organization_not_found, "The organization was not found.", %{org_id: org_id})}

  defp configured_environment do
    case StripeConfig.environment() do
      {:ok, environment} ->
        {:ok, environment}

      {:error, _reason} ->
        {:error,
         error(
           :invalid_stripe_environment,
           "Billing environment is not configured.",
           %{}
         )}
    end
  end

  # A raw query may return a NaiveDateTime for the timestamptz column; coerce
  # before any DateTime comparison.
  defp in_trial_window?(nil), do: false

  defp in_trial_window?(trial_ends_at) do
    DateTime.compare(now_utc(), to_utc(trial_ends_at)) != :gt
  end

  defp inactive(org_id, cause, status, trial_ends_at, subscription_ends_at) do
    case inactive_since(cause, trial_ends_at, subscription_ends_at) do
      {:ok, base} ->
        purge_date =
          base
          |> DateTime.add(Package.inactive_retention_days(), :day)
          |> DateTime.to_date()

        {:error,
         %EntitlementError{
           code: :plan_inactive,
           reason: :plan_inactive,
           cause: cause,
           purge_date: purge_date,
           message:
             "This organization's PostDeploy access is no longer active. " <>
               restore_hint(cause) <>
               " Its stored data will be purged on " <> Date.to_iso8601(purge_date) <> ".",
           details: %{org_id: org_id, status: status}
         }}

      :error ->
        {:error,
         error(
           :invalid_billing_state,
           "This organization's inactive subscription has no persisted retention anchor.",
           %{org_id: org_id, status: status}
         )}
    end
  end

  defp restore_hint(:trial_expired),
    do: "The free trial has ended. Subscribe on the billing page to keep writing data."

  defp restore_hint(:subscription_lapsed),
    do: "Restore the subscription on the billing page to keep writing data."

  defp inactive_since(:trial_expired, trial_ends_at, _subscription_ends_at) do
    if trial_ends_at, do: {:ok, to_utc(trial_ends_at)}, else: :error
  end

  defp inactive_since(:subscription_lapsed, trial_ends_at, subscription_ends_at) do
    cond do
      subscription_ends_at -> {:ok, to_utc(subscription_ends_at)}
      trial_ends_at -> {:ok, to_utc(trial_ends_at)}
      true -> :error
    end
  end

  defp now_utc, do: DateTime.utc_now()

  defp to_utc(%DateTime{} = value), do: value
  defp to_utc(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

  # Seats are memberships PLUS pending, unexpired invitations. Expired
  # invitations hold no seat -- they cannot be accepted. `$2` drops the one
  # invitation being accepted right now, whose reservation is becoming the
  # membership this count is deciding on.
  #
  # Warning: `statement_timestamp()`, never `now()`. `now()` is the
  # transaction's start time, and this statement runs after a wait on the
  # organization lock that can last as long as the winner's transaction. An
  # invitation that expired during that wait would still be counted, and a
  # valid seat operation would be refused for a seat nobody holds.
  # Fully parameterized ($1, $2); the SQL string is a fixed compile-time
  # literal.
  # sobelow_skip ["SQL.Query"]
  defp count_seats(org_id, except_invitation_id) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT (SELECT count(*) FROM memberships WHERE org_id = $1)
             + (SELECT count(*) FROM invitations
                WHERE org_id = $1
                  AND status = 'pending'
                  AND expires_at > statement_timestamp()
                  AND ($2::text IS NULL OR id <> $2))
        """,
        [org_id, except_invitation_id]
      )

    count
  end

  # `table`/`predicate` come from the fixed, compile-time `@capacity_metrics`
  # map (guarded by `is_map_key(@capacity_metrics, metric)` at the call site),
  # never from request data. The query itself is parameterized ($1) for org_id.
  # sobelow_skip ["SQL.Query"]
  defp count_capacity(org_id, metric) do
    {table, predicate} = Map.fetch!(@capacity_metrics, metric)

    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM #{table} WHERE org_id = $1 AND #{predicate}", [org_id])

    count
  end

  defp check_capacity(org_id, metric, current, code) do
    limit = Package.limit(metric)

    if current < limit do
      :ok
    else
      {:error,
       error(code, "PostDeploy includes #{limit} #{metric}. Remove one to add another.", %{
         org_id: org_id,
         metric: metric,
         current: current,
         limit: limit
       })}
    end
  end

  defp check_capacity_ok(metric, current) do
    limit = Package.limit(metric)

    if current < limit do
      {:ok, %{current: current, limit: limit}}
    else
      {:error,
       error(
         :monitor_limit_reached,
         "PostDeploy includes #{limit} #{monitor_noun(metric)}. Remove one to add another.",
         %{metric: metric, current: current, limit: limit}
       )}
    end
  end

  defp monitor_noun(:uptime_monitors), do: "uptime and API monitors"
  defp monitor_noun(:cron_jobs), do: "cron and heartbeat jobs"

  defp type_filter(:uptime_monitors), do: "monitors.type IN ('http', 'keyword', 'tcp', 'dns')"
  defp type_filter(:cron_jobs), do: "monitors.type = 'heartbeat'"

  defp metric_for_type(type) when type in @uptime_types, do: {:ok, :uptime_monitors}
  defp metric_for_type(type) when type in @cron_types, do: {:ok, :cron_jobs}

  defp metric_for_type(type),
    do:
      {:error,
       error(:unknown_monitor_type, "The supplied monitor type is not supported.", %{type: type})}

  defp known_channel_type(type) when type in ~w(email slack discord webhook telegram), do: :ok

  defp known_channel_type(type),
    do:
      {:error,
       error(:unknown_channel_type, "The supplied channel type is not supported.", %{type: type})}

  defp validate_ids(org_id, project_id) when is_binary(org_id) and is_binary(project_id), do: :ok

  defp validate_ids(org_id, project_id),
    do:
      {:error,
       error(:invalid_scope, "An organisation id and project id are required.", %{
         org_id: org_id,
         project_id: project_id
       })}

  defp check_interval(interval, field) when is_integer(interval) and interval > 0 do
    minimum = Package.limit(:min_check_interval_seconds)

    if interval >= minimum do
      :ok
    else
      {:error,
       error(
         :interval_not_allowed,
         "The fastest check interval is #{minimum} seconds.",
         %{
           field: field,
           requested_interval_seconds: interval,
           minimum_interval_seconds: minimum
         }
       )}
    end
  end

  defp check_interval(interval, field),
    do:
      {:error,
       error(:invalid_interval, "The requested interval must be a positive integer.", %{
         field: field,
         value: interval
       })}

  defp check_retry_interval(nil), do: :ok
  defp check_retry_interval(interval), do: check_interval(interval, :retry_interval_seconds)

  defp error(code, message, details),
    do: %EntitlementError{code: code, message: message, details: details}
end
