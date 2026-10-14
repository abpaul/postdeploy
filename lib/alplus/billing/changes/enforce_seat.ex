defmodule Alplus.Billing.Changes.EnforceSeat do
  @moduledoc """
  Refuses a create the organization has no seat for.

  One gate for all three ways a seat is taken: sending an invitation, adding
  a member directly, and accepting an invitation. A seat is a membership OR a
  pending, unexpired invitation, so an invitation reserves the seat it will
  become and a later direct add cannot take that seat away.

  Set `:except_invitation_argument` on the accept path only. It names the
  action argument that carries the invitation being redeemed, whose own
  reservation must not count against the membership it becomes.

  The error carries no field. It is written for the person reading it, and
  the invite form renders only `email` and `role`, so a field-bound error
  would never reach the screen.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    except_argument = Keyword.get(opts, :except_invitation_argument)

    # This callback executes in Ash's create transaction, where the gate's
    # organization lock is held until the insert commits.
    Ash.Changeset.before_action(changeset, fn changeset ->
      org_id = Ash.Changeset.get_attribute(changeset, :org_id)
      except = except_argument && Ash.Changeset.get_argument(changeset, except_argument)

      case Alplus.Billing.Access.allow_seat(org_id, except_invitation_id: except) do
        :ok -> changeset
        {:error, %{message: message}} -> Ash.Changeset.add_error(changeset, message: message)
      end
    end)
  end
end
