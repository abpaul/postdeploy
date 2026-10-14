defmodule Alplus.Orgs.Changes.StartTrial do
  @moduledoc """
  Starts or resumes the creating account's one trial.

  The account-level claim is created inside the organization transaction.
  An organization replacement therefore keeps the original trial deadline.
  """

  use Ash.Resource.Change

  alias Alplus.Billing.Package

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      with %{user_id: user_id} <- context.actor,
           {:ok, claim} <-
             Alplus.Billing.claim_trial(%{user_id: user_id}, authorize?: false) do
        changeset
        |> Ash.Changeset.force_change_attribute(:billing_status, :trialing)
        |> Ash.Changeset.force_change_attribute(
          :trial_ends_at,
          DateTime.add(claim.started_at, Package.trial_days(), :day)
        )
      else
        nil -> Ash.Changeset.add_error(changeset, message: "trial requires an account")
        {:error, error} -> Ash.Changeset.add_error(changeset, error)
      end
    end)
  end
end
