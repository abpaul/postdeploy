defmodule Alplus.Mail do
  @moduledoc """
  Builds every outgoing PostDeploy email from one message spec.

  A sender describes the message and never writes markup:

      Alplus.Mail.build(
        to: "person@example.com",
        subject: "Reset your password",
        heading: "Reset your password",
        paragraphs: ["Someone asked to reset the password for this address."],
        action: {"Reset password", url},
        note: "If it wasn't you, ignore this email. Nothing has changed.",
        footer_note: "You received this because a password reset was requested."
      )

  `Alplus.Mailer.Worker` owns delivery and retry. This module only builds the
  message so request and action processes never perform SMTP work.

  `AlplusWeb.Emails.MailTemplate` renders the spec twice, once as HTML and
  once as plain text, so both parts are always present and always say the same
  thing. That is not tidiness: a single-link HTML-only body is a strong spam
  signal, and `Alplus.MailPartsTest` asserts the invariant.

  ## Options

    * `:to` - required recipient.
    * `:subject` - required.
    * `:heading` - the h1. Defaults to the subject, which is usually right:
      the subject line is the promise and the heading keeps it.
    * `:paragraphs` - required, a list of plain strings. Interpolated values
      are escaped by the template; senders pass raw user data safely.
    * `:detail` - optional single line set in the monospace face under the
      paragraphs, for a code location.
    * `:facts` - optional list of `{label, value}` pairs, rendered as a table.
    * `:action` - optional `{label, url}`. One action per message.
    * `:note` - optional supporting fact under the action (an expiry, a
      reassurance).
    * `:footer_note` - optional reason-for-receipt line.
    * `:preheader` - optional inbox preview line. Defaults to paragraph one.
    * `:from` - optional, defaults to `Alplus.Mailer.from_address/0`.
  """

  import Swoosh.Email

  alias Alplus.Mailer
  alias AlplusWeb.Emails.MailTemplate

  @spec build(keyword()) :: Swoosh.Email.t()
  def build(opts) do
    spec = spec(opts)

    new()
    |> from(Keyword.get_lazy(opts, :from, &Mailer.from_address/0))
    |> to(Keyword.fetch!(opts, :to))
    |> subject(Keyword.fetch!(opts, :subject))
    |> html_body(MailTemplate.html(spec))
    |> text_body(MailTemplate.text(spec))
  end

  defp spec(opts) do
    %{
      heading: Keyword.get(opts, :heading) || Keyword.fetch!(opts, :subject),
      paragraphs: Keyword.fetch!(opts, :paragraphs),
      detail: Keyword.get(opts, :detail),
      facts: Keyword.get(opts, :facts, []),
      action: action(Keyword.get(opts, :action)),
      note: Keyword.get(opts, :note),
      footer_note: Keyword.get(opts, :footer_note),
      preheader: Keyword.get(opts, :preheader)
    }
  end

  defp action(nil), do: nil
  defp action({label, url}), do: %{label: label, url: url}
end
