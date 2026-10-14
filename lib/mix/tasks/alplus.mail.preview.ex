defmodule Mix.Tasks.Alplus.Mail.Preview do
  @shortdoc "Delivers one of every PostDeploy email into the local mailbox"

  @moduledoc """
  Renders every email variant through `Alplus.Mail` and writes it to `tmp/`.

      mix alplus.mail.preview

  This is the loop for changing `AlplusWeb.Emails.MailTemplate`: edit the
  template, run this, reload the files in a browser. Toggle the OS to dark
  mode to check the dark arm.

  Files rather than the `/dev/mailbox` preview, because the Local adapter
  keeps its mailbox in the node that sent the mail, and a Mix task is not the
  node running `mix phx.server`.

  The specs below are literal, so a variant that only appears under a rare
  runtime condition (the identity-link confirmation, an alert with no action)
  is still one keystroke away.
  """

  use Mix.Task

  alias Alplus.Mail

  @requirements ["app.config"]

  @token "tok_2f8c1d9ba4e7c05f3a6b8d21e4f70c93"
  @dir "tmp/mail-preview"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    File.mkdir_p!(@dir)

    Enum.each(previews(), fn {name, opts} ->
      email = Mail.build([to: "preview@example.com"] ++ opts)
      path = Path.join(@dir, "#{name}.html")
      File.write!(path, email.html_body)
      File.write!(Path.join(@dir, "#{name}.txt"), email.text_body)
      Mix.shell().info(path)
    end)

    Mix.shell().info("\nOpen: open #{@dir}/*.html")
  end

  defp previews do
    [
      {"error-alert",
       [
         subject:
           "[Storm Portal] New error: Airtable::Client::RequestError: upsert_record failed (503)",
         heading: "New error in Storm Portal",
         paragraphs: ["Airtable::Client::RequestError: Airtable upsert_record failed (503)"],
         detail: "app/services/airtable/client.rb:upsert_record",
         facts: [
           {"Environment", "production"},
           {"Level", "error"},
           {"Events", "3"},
           {"First seen", "2026-10-01 23:01 UTC"},
           {"Last seen", "2026-10-01 23:01 UTC"},
           {"Release", "a235662b8fac"}
         ],
         action: {"Open the issue", link("/dashboard")},
         footer_note:
           "You received this because a PostDeploy notification channel sends alerts to this address."
       ]},
      {"password-reset",
       [
         subject: "Reset your password",
         paragraphs: ["Someone asked to reset the password for this PostDeploy account."],
         action: {"Reset password", link("/password-reset")},
         note: "If it wasn't you, ignore this email. Nothing has changed.",
         footer_note: "You received this because a password reset was requested for this address."
       ]},
      {"new-user-confirmation",
       [
         subject: "Confirm your email address",
         paragraphs: ["Confirm this address to finish setting up your PostDeploy account."],
         action: {"Confirm email address", link("/confirm_new_user")},
         footer_note: "You received this because this address was used to sign up for PostDeploy."
       ]},
      {"identity-link",
       [
         subject: "Confirm linking your GitHub login",
         paragraphs: [
           "Someone signed in with GitHub using your email address and wants to link it to your PostDeploy account.",
           "Confirming lets that GitHub login into this account."
         ],
         action: {"Link GitHub login", link("/confirm_new_user")},
         note: "If it wasn't you, ignore this email. Nothing has changed.",
         footer_note: "You received this because a GitHub login matched this address."
       ]},
      {"invitation",
       [
         subject: "You've been invited to join Acme Industries on PostDeploy",
         heading: "Join Acme Industries on PostDeploy",
         paragraphs: [
           "You've been invited to join Acme Industries on PostDeploy as admin.",
           "PostDeploy watches that organization's uptime, traffic, and errors in one place."
         ],
         action: {"Accept invitation", link("/invitations")},
         note: "This invitation expires in 7 days.",
         footer_note: "You received this because Acme Industries invited this address."
       ]},
      {"alert",
       [
         subject: "PostDeploy down: monitor mon_2f8c1d9ba4e7c05f",
         paragraphs: ["PostDeploy notification: down for monitor mon_2f8c1d9ba4e7c05f."],
         footer_note:
           "You received this because an PostDeploy notification channel sends alerts to this address."
       ]}
    ]
  end

  defp link(path), do: "#{AlplusWeb.Endpoint.url()}#{path}/#{@token}"
end
