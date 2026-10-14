defmodule Alplus.Accounts.Validations.NotPwned do
  @moduledoc """
  Rejects a password found in the Have I Been Pwned breach corpus
  (ARCHITECTURE.md §10). Calls `Alplus.Accounts.Hibp.Client`, which never sends
  the password itself over the network (k-anonymity range query).

  Warning: if the HIBP call fails (timeout, non-200, network error), this
  fails closed by default — the password is rejected, not silently
  accepted, per the no-silent-fallbacks rule. Flip
  `config :alplus, :hibp_fail_closed?` to `false` to fail open instead
  (accepting the password and logging the outage) if availability during
  an HIBP outage matters more than this extra check.

  Usage: `validate {Alplus.Accounts.Validations.NotPwned, argument: :password}`
  """

  use Ash.Resource.Validation

  require Logger

  alias Ash.Error.Changes.InvalidArgument

  @impl true
  def validate(changeset, opts, _context) do
    argument = Keyword.fetch!(opts, :argument)

    case Ash.Changeset.get_argument(changeset, argument) do
      nil -> :ok
      password -> check(password, argument)
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: validate(changeset, opts, context)

  defp check(password, argument) do
    case Alplus.Accounts.Hibp.Client.pwned?(password) do
      {:ok, true} ->
        {:error,
         InvalidArgument.exception(
           field: argument,
           message: "has appeared in a data breach. Choose a different password."
         )}

      {:ok, false} ->
        :ok

      {:error, reason} ->
        handle_unavailable(reason, argument)
    end
  end

  defp handle_unavailable(reason, argument) do
    Logger.warning("HIBP check unavailable: #{inspect(reason)}")

    if Application.get_env(:alplus, :hibp_fail_closed?, true) do
      {:error,
       InvalidArgument.exception(
         field: argument,
         message: "could not be checked against known breaches right now. Try again shortly."
       )}
    else
      :ok
    end
  end
end
