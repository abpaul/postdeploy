defmodule Alplus.Orgs.Invitation.Senders.SendInvitationEmail do
  @moduledoc """
  Sends the invitation accept-link email, mirroring
  `Alplus.Accounts.User.Senders.SendNewUserConfirmationEmail`'s pattern.
  Called from `Alplus.Orgs.Invitation.Changes.SendInvitationEmail` for both
  `:invite` and `:resend`.
  """

  use AlplusWeb, :verified_routes

  alias Alplus.Mail
  alias Alplus.Mailer.Worker

  @doc "`invitation` must have `:token_hash` and `:id`. The worker loads its organization before building the email."
  @spec send(Alplus.Orgs.Invitation.t(), String.t()) :: :ok
  def send(invitation, token) do
    Worker.enqueue!(%{
      "purpose" => "invitation",
      "record_id" => invitation.token_hash,
      "invitation_id" => invitation.id,
      "token" => token
    })

    :ok
  end

  @doc false
  def build(invitation, token) do
    organization = invitation.organization.name

    Mail.build(
      to: to_string(invitation.email),
      subject: "You've been invited to join #{organization} on PostDeploy",
      heading: "Join #{organization} on PostDeploy",
      paragraphs: [
        "You've been invited to join #{organization} on PostDeploy as #{invitation.role}.",
        "PostDeploy watches that organization's uptime, traffic, and errors in one place."
      ],
      action: {"Accept invitation", url(~p"/invitations/#{token}")},
      note: "This invitation expires in 7 days.",
      footer_note: "You received this because #{organization} invited this address."
    )
  end
end
