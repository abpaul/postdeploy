defmodule Alplus.Orgs.Invitation.Changes.AcceptInvitation do
  @moduledoc """
  Validates the raw `token` argument against this invitation (already
  found by token hash — see `Alplus.Orgs.accept_invitation/2`, which is
  what looks it up before calling this action), confirms the accepting
  actor's own account email matches the invited email, then creates the
  actor's membership in the same transaction.

  Token possession alone is not enough: anyone who intercepts an invite
  link is an authenticated actor and could otherwise accept it under
  their own account, joining at the invited role. The email check closes
  that gap — the accepting account must be the one the invite named.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    token = Ash.Changeset.get_argument(changeset, :token)
    invitation = changeset.data
    actor = context.actor

    cond do
      is_nil(actor) ->
        Ash.Changeset.add_error(changeset,
          field: :token,
          message: "requires an authenticated actor"
        )

      is_nil(token) or Alplus.Security.BearerToken.hash(token) != invitation.token_hash ->
        Ash.Changeset.add_error(changeset, field: :token, message: "is invalid")

      invitation.status != "pending" ->
        Ash.Changeset.add_error(changeset, field: :token, message: "is no longer pending")

      DateTime.compare(DateTime.utc_now(), invitation.expires_at) != :lt ->
        Ash.Changeset.add_error(changeset, field: :token, message: "has expired")

      not actor_email_matches?(actor, invitation) ->
        Ash.Changeset.add_error(changeset,
          field: :token,
          message: "was sent to a different email address than your account's"
        )

      true ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, "accepted")
        |> Ash.Changeset.force_change_attribute(:accepted_at, DateTime.utc_now())
        |> Ash.Changeset.before_action(fn changeset ->
          create_membership(changeset, invitation, actor)
        end)
    end
  end

  defp actor_email_matches?(actor, invitation) do
    case Ash.get(Alplus.Accounts.User, actor.user_id, authorize?: false) do
      {:ok, %{email: email}} -> normalize(to_string(email)) == invitation.email
      _ -> false
    end
  end

  defp normalize(email), do: email |> String.trim() |> String.downcase()

  defp create_membership(changeset, invitation, actor) do
    Alplus.Orgs.Membership
    |> Ash.create(
      %{
        org_id: invitation.org_id,
        user_id: actor.user_id,
        role: invitation.role,
        invitation_id: invitation.id
      },
      action: :create_from_invitation,
      authorize?: false
    )
    |> case do
      {:ok, _membership} -> changeset
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end
end
