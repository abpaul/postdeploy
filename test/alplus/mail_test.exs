defmodule Alplus.MailTest do
  @moduledoc """
  The shell's contracts. `Alplus.MailPartsTest` asserts every sender carries
  both parts; this asserts what the shell guarantees to any sender, present
  or future.
  """
  use ExUnit.Case, async: true

  alias Alplus.Mail

  defp reset_email(overrides \\ []) do
    [
      to: "person@example.com",
      subject: "Reset your password",
      paragraphs: ["Someone asked to reset the password for this PostDeploy account."],
      action: {"Reset password", "https://postdeploy.dev/password-reset/tok_abc"}
    ]
    |> Keyword.merge(overrides)
    |> Mail.build()
  end

  test "one spec produces both parts, and the action reaches both" do
    email = reset_email()

    assert email.html_body =~ "https://postdeploy.dev/password-reset/tok_abc"
    assert email.text_body =~ "https://postdeploy.dev/password-reset/tok_abc"
    assert email.html_body =~ "Reset password"
    assert email.text_body =~ "Reset password:"
  end

  test "the heading defaults to the subject" do
    email = reset_email()

    assert email.html_body =~ "<h1"
    assert email.html_body =~ "Reset your password"
    assert email.subject == "Reset your password"
  end

  test "user-supplied content is escaped, never injected" do
    email =
      reset_email(
        subject: "You've been invited to join <script>alert(1)</script> on PostDeploy",
        paragraphs: ["Sanders & Sons <b>invited</b> you."]
      )

    refute email.html_body =~ "<script>"
    refute email.html_body =~ "<b>invited</b>"
    assert email.html_body =~ "&lt;script&gt;"
    assert email.html_body =~ "Sanders &amp; Sons"
  end

  test "a message with no action renders without the fallback-link block" do
    email =
      Mail.build(
        to: "person@example.com",
        subject: "PostDeploy down: monitor mon_1",
        paragraphs: ["PostDeploy notification: down for monitor mon_1."]
      )

    refute email.html_body =~ "paste this link"
    assert email.html_body =~ "PostDeploy notification: down for monitor mon_1."
    assert email.text_body =~ "PostDeploy notification: down for monitor mon_1."
  end

  test "the from address defaults to the mailer's, and an override wins" do
    assert reset_email().from == Alplus.Mailer.from_address()
    assert reset_email(from: "alerts@postdeploy.dev").from == {"", "alerts@postdeploy.dev"}
  end

  test "the inbox preview line defaults to the first paragraph" do
    assert reset_email().html_body =~ "Someone asked to reset the password"
    assert reset_email(preheader: "Act within the hour.").html_body =~ "Act within the hour."
  end

  test "a spec with no heading and no subject is a build error, not a blank email" do
    assert_raise KeyError, fn ->
      Mail.build(to: "person@example.com", paragraphs: ["Body."])
    end
  end
end
