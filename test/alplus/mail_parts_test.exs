defmodule Alplus.MailPartsTest do
  @moduledoc """
  Every transactional email carries both a text and an HTML part.

  A single-link HTML-only body is a strong spam signal. On 2026-08-20 a
  password reset was accepted by the relay (`2.0.0 Ok`), never reached the
  inbox, and produced no bounce: iCloud discards such mail from a domain with
  no sending history. A plain-text probe through the same relay arrived.

  These are the four senders that carry a link a person must click. If one
  loses its text part, the mail still "sends" and the user still never sees
  it, which is why this is asserted rather than reviewed.
  """
  use Alplus.DataCase, async: true

  alias Alplus.Accounts.User.Senders.SendEmailChangeConfirmationEmail
  alias Alplus.Accounts.User.Senders.SendNewUserConfirmationEmail
  alias Alplus.Accounts.User.Senders.SendPasswordResetEmail
  alias Alplus.Orgs.Invitation.Senders.SendInvitationEmail

  defp assert_both_parts(email, token) do
    assert is_binary(email.html_body) and email.html_body =~ token
    assert is_binary(email.text_body) and email.text_body =~ token
    # A text part that is only the URL reads as spam too; it should say what
    # the link does.
    assert String.length(String.trim(email.text_body)) > String.length(token) + 10
  end

  test "password reset" do
    email = SendPasswordResetEmail.build(%{email: "reset@example.com"}, "tok_reset", %{})
    assert_both_parts(email, "tok_reset")
  end

  test "new user confirmation" do
    email = SendNewUserConfirmationEmail.build(%{email: "confirm@example.com"}, "tok_confirm", [])
    assert_both_parts(email, "tok_confirm")
  end

  test "new user confirmation, identity-link variant" do
    email =
      SendNewUserConfirmationEmail.build(%{email: "link@example.com"}, "tok_link",
        confirmation_type: :identity_link,
        provider: "github"
      )

    assert_both_parts(email, "tok_link")
  end

  test "email change confirmation" do
    email =
      SendEmailChangeConfirmationEmail.build(%{email: "old@example.com"}, "tok_change",
        pending_email: "new@example.com"
      )

    assert_both_parts(email, "tok_change")
  end

  test "organization invitation" do
    invitation = %{
      email: "invitee@example.com",
      role: "member",
      organization: %{name: "Acme"}
    }

    email = SendInvitationEmail.build(invitation, "tok_invite")
    assert_both_parts(email, "tok_invite")
  end
end
