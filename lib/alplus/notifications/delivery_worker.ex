defmodule Alplus.Notifications.DeliveryWorker do
  @moduledoc """
  Delivers one notification through the durable `notify` queue.

  The delivery row is claimed before an adapter runs. A duplicate job therefore
  cannot send while a prior claim is live, and a failed claim can be retried
  after its lease expires. Channel configuration is decrypted only in memory
  and is never included in worker errors or logs.
  """

  use Oban.Worker, queue: :notify, max_attempts: 10

  alias Alplus.Billing.{Access, EntitlementError}
  alias Alplus.Notifications.{Adapters, Channel}
  alias Alplus.Repo

  @claim_ttl_seconds 120
  @types ~w(email slack discord webhook telegram)

  @required_args ~w(org_id channel_id channel_type trigger subject_type subject_id repeat_index)

  @spec enqueue(map()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(args) when is_map(args) do
    with :ok <- validate_args(args) do
      new(args) |> Oban.insert()
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    case claim_delivery(job) do
      {:ok, claim, channel} ->
        finish(claim, Adapters.deliver(channel.type, channel.config, event(job.args)))

      :duplicate ->
        :ok

      {:error, :plan_gated} ->
        {:cancel, "channel_plan_gated"}

      {:error, :not_found} ->
        {:cancel, "channel_not_found"}

      {:error, :invalid_args} ->
        {:cancel, "invalid_notification_args"}
    end
  end

  # `occurrence` names one instance of a recurring event on the same subject,
  # such as the expiry date of the certificate a warning is about. Without it,
  # a renewed certificate would reuse the first certificate's ledger row and
  # never warn.
  @spec dedup_key(map()) :: String.t()
  def dedup_key(args) do
    material =
      ([
         Map.fetch!(args, "channel_id"),
         Map.fetch!(args, "subject_type"),
         Map.fetch!(args, "subject_id"),
         Map.fetch!(args, "trigger"),
         Map.fetch!(args, "repeat_index")
       ] ++ List.wrap(args["occurrence"]))
      |> Enum.join(":")

    "notify:" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  @doc """
  Gates every channel against the organization's current plan at delivery
  time (issue #61). The
  plan frozen into the Oban args at enqueue time is stale by definition:
  a job enqueued while active must not deliver after expiry.
  """
  @spec check_channel_plan(String.t(), String.t()) :: :ok | {:error, :plan_gated}
  def check_channel_plan(type, org_id) when type in @types and is_binary(org_id) do
    case Access.allow_notification_channel(org_id, type) do
      :ok -> :ok
      {:error, %EntitlementError{}} -> {:error, :plan_gated}
    end
  end

  def check_channel_plan(_type, _org_id), do: {:error, :plan_gated}

  defp fetch_channel(%{"channel_id" => channel_id, "org_id" => org_id, "channel_type" => type}) do
    case Ash.get(Channel, channel_id, authorize?: false, load: [:config]) do
      {:ok, %{org_id: ^org_id, type: ^type} = channel} -> {:ok, channel}
      _ -> {:error, :not_found}
    end
  end

  defp claim_delivery(job) do
    with :ok <- validate_args(job.args),
         {:ok, channel} <- fetch_channel(job.args),
         :ok <- check_channel_plan(channel.type, channel.org_id),
         {:ok, claim} <- claim(job, channel) do
      {:ok, claim, channel}
    end
  end

  defp claim(job, channel) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    expires_at = DateTime.add(now, @claim_ttl_seconds, :second)
    token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    dedup_key = dedup_key(job.args)

    case Repo.query!(
           """
           INSERT INTO notification_deliveries
             (id, org_id, alert_rule_id, channel_id, channel_type, trigger, subject_type, subject_id,
              dedup_key, job_id, attempt, claimed_at, claim_expires_at, claim_token, status, inserted_at, updated_at)
           VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,1,$11,$12,$13,'pending',$11,$11)
           ON CONFLICT (dedup_key) DO NOTHING
           RETURNING id
           """,
           [
             Alplus.Id.generate(:notification_delivery),
             job.args["org_id"],
             Map.get(job.args, "alert_rule_id"),
             channel.id,
             channel.type,
             job.args["trigger"],
             job.args["subject_type"],
             job.args["subject_id"],
             dedup_key,
             Integer.to_string(job.id),
             now,
             expires_at,
             token
           ]
         ) do
      %{rows: [[id]]} -> {:ok, %{id: id, token: token, dedup_key: dedup_key}}
      %{rows: []} -> reclaim(dedup_key, token, now, expires_at)
    end
  end

  defp reclaim(dedup_key, token, now, expires_at) do
    case Repo.query!(
           """
           UPDATE notification_deliveries
           SET status = 'pending', attempt = attempt + 1, claimed_at = $2,
               claim_expires_at = $3, claim_token = $4, error_message = NULL, updated_at = $2
           WHERE dedup_key = $1
             AND status IN ('failed', 'pending')
             AND claim_expires_at <= $2
           RETURNING id
           """,
           [dedup_key, now, expires_at, token]
         ) do
      %{rows: [[id]]} -> {:ok, %{id: id, token: token, dedup_key: dedup_key}}
      %{rows: []} -> :duplicate
    end
  end

  defp finish(claim, :ok) do
    Repo.query!(
      """
      UPDATE notification_deliveries
      SET status = 'sent', sent_at = $3, updated_at = $3, error_message = NULL
      WHERE id = $1 AND claim_token = $2 AND status = 'pending'
      """,
      [claim.id, claim.token, DateTime.utc_now() |> DateTime.truncate(:microsecond)]
    )

    :ok
  end

  defp finish(claim, {:error, kind}) when kind in [:retryable, :permanent] do
    status = if kind == :permanent, do: "skipped", else: "failed"
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.query!(
      """
      UPDATE notification_deliveries
      SET status = $3, error_message = $4, claim_expires_at = $5, updated_at = $5
      WHERE id = $1 AND claim_token = $2 AND status = 'pending'
      """,
      [claim.id, claim.token, status, Atom.to_string(kind), now]
    )

    if kind == :permanent,
      do: {:cancel, "delivery_permanent_failure"},
      else: {:error, :delivery_retryable_failure}
  end

  defp event(args), do: Map.take(args, ["org_id", "trigger", "subject_type", "subject_id"])

  defp validate_args(args) do
    if Enum.all?(@required_args, &(is_binary(args[&1]) and byte_size(args[&1]) > 0)) and
         args["channel_type"] in @types and integer_string?(args["repeat_index"]) do
      :ok
    else
      {:error, :invalid_args}
    end
  end

  defp integer_string?(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> true
      _ -> false
    end
  end
end
