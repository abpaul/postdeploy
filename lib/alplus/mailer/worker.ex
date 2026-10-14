defmodule Alplus.Mailer.Worker do
  @moduledoc """
  Delivers transactional mail from durable, idempotent Oban jobs.

  Jobs contain a purpose, a persisted record id, and the one-time token needed
  to render that record's link. The delivery ledger prevents replaying a
  successful logical delivery.
  """

  use Oban.Worker,
    queue: :mailer,
    max_attempts: 10,
    unique: [
      period: :infinity,
      keys: [:purpose, :record_id],
      states: :successful,
      fields: [:worker, :queue, :args]
    ]

  alias Alplus.Accounts.User

  alias Alplus.Accounts.User.Senders.{
    SendEmailChangeConfirmationEmail,
    SendNewUserConfirmationEmail,
    SendPasswordResetEmail
  }

  alias Alplus.Orgs.Invitation
  alias Alplus.Orgs.Invitation.Senders.SendInvitationEmail
  alias Alplus.Repo

  @claim_ttl_seconds 120
  @purposes ~w(user_confirmation password_reset email_change invitation)

  @spec enqueue(map()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(args) when is_map(args) do
    with :ok <- validate_args(args) do
      new(args) |> Oban.insert()
    end
  end

  @spec enqueue!(map()) :: Oban.Job.t()
  def enqueue!(args) when is_map(args) do
    case validate_args(args) do
      :ok -> args |> new() |> Oban.insert!()
      {:error, :invalid_args} -> raise ArgumentError, "invalid mail args"
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: 30_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case validate_args(args) do
      :ok -> perform_valid(args)
      {:error, :invalid_args} -> {:cancel, "invalid_mail_args"}
    end
  end

  defp perform_valid(args) do
    case claim(args) do
      {:ok, claim} ->
        case deliver(args) do
          :ok -> finish(claim, :ok)
          :stale -> finish(claim, :ok)
          {:error, :permanent} -> finish(claim, :permanent)
          {:error, _reason} -> finish(claim, :retryable)
        end

      :duplicate ->
        :ok
    end
  end

  @spec dedup_key(map()) :: String.t()
  def dedup_key(args) do
    "mail:" <>
      Base.url_encode64(
        :crypto.hash(:sha256, Enum.join([args["purpose"], args["record_id"]], ":")),
        padding: false
      )
  end

  defp claim(args) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    expires_at = DateTime.add(now, @claim_ttl_seconds, :second)
    token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    id = Alplus.Id.generate(:mail_delivery)

    case Repo.query!(
           """
           INSERT INTO mail_deliveries
             (id, purpose, record_id, status, attempts, claim_token, claim_expires_at, inserted_at, updated_at)
           VALUES ($1, $2, $3, 'pending', 1, $4, $5, $6, $6)
           ON CONFLICT (purpose, record_id) DO NOTHING
           RETURNING id
           """,
           [id, args["purpose"], args["record_id"], token, expires_at, now]
         ) do
      %{rows: [[delivery_id]]} -> {:ok, %{id: delivery_id, token: token}}
      %{rows: []} -> reclaim(args, token, now, expires_at)
    end
  end

  defp reclaim(args, token, now, expires_at) do
    case Repo.query!(
           """
           UPDATE mail_deliveries
           SET status = 'pending', attempts = attempts + 1, claim_token = $3,
               claim_expires_at = $4, error_message = NULL, updated_at = $2
           WHERE purpose = $1
             AND record_id = $5
             AND (status = 'failed' OR (status = 'pending' AND claim_expires_at <= $2))
           RETURNING id
           """,
           [args["purpose"], now, token, expires_at, args["record_id"]]
         ) do
      %{rows: [[delivery_id]]} -> {:ok, %{id: delivery_id, token: token}}
      %{rows: []} -> :duplicate
    end
  end

  defp finish(claim, :ok) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.query!(
      """
      UPDATE mail_deliveries
      SET status = 'sent', sent_at = $3, claim_expires_at = NULL,
          claim_token = NULL, error_message = NULL, updated_at = $3
      WHERE id = $1 AND claim_token = $2 AND status = 'pending'
      """,
      [claim.id, claim.token, now]
    )

    :ok
  end

  defp finish(claim, kind) when kind in [:retryable, :permanent] do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    status = "failed"

    Repo.query!(
      """
      UPDATE mail_deliveries
      SET status = $3, error_message = $4, claim_expires_at = $5,
          claim_token = NULL, updated_at = $5
      WHERE id = $1 AND claim_token = $2 AND status = 'pending'
      """,
      [claim.id, claim.token, status, Atom.to_string(kind), now]
    )

    if kind == :permanent do
      {:cancel, "mail_delivery_permanent_failure"}
    else
      {:error, :mail_delivery_failed}
    end
  end

  defp deliver(args) do
    with {:ok, email} <- build_email(args) do
      case Alplus.Mailer.deliver(email) do
        {:ok, _metadata} -> :ok
        {:error, reason} -> {:error, classify_error(reason)}
      end
    else
      {:stale, _reason} -> :stale
      {:error, :not_found} -> {:error, :permanent}
      {:error, :invalid_args} -> {:error, :permanent}
    end
  rescue
    _error -> {:error, :retryable}
  end

  defp classify_error({:permanent, _reason}), do: :permanent
  defp classify_error(:invalid_email), do: :permanent
  defp classify_error(:invalid_recipient), do: :permanent
  defp classify_error(%{status: status}), do: classify_status(status)
  defp classify_error({status, _reason}) when is_integer(status), do: classify_status(status)

  defp classify_error({code, _reason}) when is_binary(code) do
    case Integer.parse(code) do
      {status, _} -> classify_status(status)
      :error -> :retryable
    end
  end

  defp classify_error(_reason), do: :retryable

  defp classify_status(status) when is_integer(status) and status in 400..499, do: :permanent
  defp classify_status(_status), do: :retryable

  defp build_email(%{"purpose" => "user_confirmation"} = args) do
    with {:ok, user} <- get(User, args["user_id"]) do
      {:ok,
       SendNewUserConfirmationEmail.build(user, args["token"],
         confirmation_type: confirmation_type(args),
         provider: args["provider"]
       )}
    end
  end

  defp build_email(%{"purpose" => "password_reset"} = args) do
    with {:ok, user} <- get(User, args["user_id"]) do
      {:ok, SendPasswordResetEmail.build(user, args["token"], [])}
    end
  end

  defp build_email(%{"purpose" => "email_change"} = args) do
    with {:ok, user} <- get(User, args["user_id"]) do
      {:ok,
       SendEmailChangeConfirmationEmail.build(user, args["token"],
         pending_email: args["pending_email"]
       )}
    end
  end

  defp build_email(%{"purpose" => "invitation"} = args) do
    with {:ok, invitation} <- get(Invitation, args["invitation_id"], load: [:organization]),
         :ok <- validate_invitation_for_delivery(invitation, args) do
      {:ok, SendInvitationEmail.build(invitation, args["token"])}
    else
      {:error, :stale_invitation} -> {:stale, :stale_invitation}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_email(_args), do: {:error, :invalid_args}

  defp validate_invitation_for_delivery(invitation, args) do
    if invitation.status == "pending" and
         invitation.token_hash == args["record_id"] and
         DateTime.compare(DateTime.utc_now(), invitation.expires_at) == :lt do
      :ok
    else
      {:error, :stale_invitation}
    end
  end

  defp get(resource, id, opts \\ []) do
    loads = Keyword.get(opts, :load, [])

    with {:ok, record} when not is_nil(record) <- Ash.get(resource, id, authorize?: false),
         {:ok, loaded} <- Ash.load(record, loads, authorize?: false) do
      {:ok, loaded}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp confirmation_type(%{"confirmation_type" => "identity_link"}), do: :identity_link
  defp confirmation_type(_args), do: nil

  defp validate_args(args) do
    required? =
      Enum.all?(["purpose", "record_id", "token"], fn key ->
        is_binary(args[key]) and byte_size(args[key]) > 0
      end)

    valid_purpose? = args["purpose"] in @purposes
    valid_user? = args["purpose"] == "invitation" or is_binary(args["user_id"])
    valid_invitation? = args["purpose"] != "invitation" or is_binary(args["invitation_id"])
    valid_pending_email? = args["purpose"] != "email_change" or is_binary(args["pending_email"])

    valid_identity_link? =
      args["purpose"] != "user_confirmation" or
        args["confirmation_type"] != "identity_link" or
        is_binary(args["provider"])

    if required? and valid_purpose? and valid_user? and valid_invitation? and
         valid_pending_email? and valid_identity_link? do
      :ok
    else
      {:error, :invalid_args}
    end
  end
end
