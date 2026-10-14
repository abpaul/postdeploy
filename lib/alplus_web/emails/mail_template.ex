defmodule AlplusWeb.Emails.MailTemplate do
  @moduledoc """
  The one visual shell every PostDeploy email renders through.

  This module is the whole design surface for mail: change it here and every
  message changes. Senders never write markup. They hand `Alplus.Mail.build/1`
  a message spec and it calls `html/1` and `text/1` below on the same spec, so
  the HTML and the text part can never drift apart.

  ## The message spec

      %{
        heading: "Reset your password",          # required, the h1
        paragraphs: ["One or more paragraphs."], # required, plain strings
        detail: "lib/app/checkout.ex:charge/1",  # optional, one monospace line
        facts: [{"Environment", "production"}],  # optional label and value rows
        action: %{label: "Reset password", url: url},  # optional single action
        note: "This link expires in 1 hour.",    # optional supporting fact
        footer_note: "You asked for this...",    # optional reason-for-receipt
        preheader: "..."                         # optional, defaults to paragraph 1
      }

  One action per message, by design: a transactional mail asks for exactly one
  thing, and a second button is a second ask.

  ## Why the markup looks like 2003

  Mail clients are not browsers. Word renders Outlook on Windows, Gmail strips
  `<style>` on some paths, and no client guarantees anything beyond tables and
  inline styles. So: presentation tables, inline styles on every element, one
  600px column. The `<style>` block carries only progressive enhancement (the
  display webfont, dark mode, the narrow-screen step) and every rule in it is
  a refinement the message survives losing.

  Token values are inlined as literal hex rather than read from
  `assets/css/alp/tokens.css`, because mail has no CSS custom properties and
  no build step. When a token moves, it moves here too. The light values come
  from `tokens.css`, the dark ones from `dark.css`, and the accent from
  `theme-console.css`.
  """

  use Phoenix.Component
  use AlplusWeb, :verified_routes

  alias Phoenix.HTML.Safe

  # The palette and type stacks the template draws with. These are assigns,
  # not module attributes, because inside `~H` `@name` always means
  # `assigns.name`. Light values from tokens.css, accent from
  # theme-console.css; the dark arm lives in the `<style>` block below.
  defp theme do
    %{
      canvas: "#FAFAFA",
      surface: "#FFFFFF",
      surface_2: "#F3F4F5",
      border: "#E6E7EA",
      rule: "#101217",
      text: "#101217",
      text_secondary: "#41434B",
      text_muted: "#50525A",
      ink_band: "#08090C",
      ink_band_text: "#FAFAFA",
      accent: "#b8d44a",
      accent_ink: "#101217",
      sans: "system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif",
      mono: "ui-monospace, 'SF Mono', Menlo, Consolas, 'Cascadia Code', monospace",
      display:
        "'Archivo', system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
    }
  end

  @doc "Renders the message spec as a full HTML document."
  @spec html(map()) :: String.t()
  def html(spec) do
    spec
    |> assigns()
    |> document()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  @doc """
  Renders the message spec as plain text.

  Every message carries this part. A single-link HTML-only body is a strong
  spam signal: on 2026-08-20 a password reset was accepted by the relay
  (`2.0.0 Ok`), never arrived, and never bounced, because iCloud discards such
  mail from a domain with no sending history.
  """
  @spec text(map()) :: String.t()
  def text(spec) do
    a = assigns(spec)

    [
      "PostDeploy",
      "",
      a.heading,
      String.duplicate("=", String.length(a.heading)),
      "",
      Enum.intersperse(a.paragraphs, ""),
      detail_text(a.detail),
      facts_text(a.facts),
      action_text(a.action),
      note_text(a.note),
      "",
      "--",
      footer_text(a.footer_note),
      url(~p"/")
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp detail_text(nil), do: []
  defp detail_text(detail), do: ["", detail]

  defp facts_text([]), do: []

  defp facts_text(facts),
    do: ["" | Enum.map(facts, fn {label, value} -> "#{label}: #{value}" end)]

  defp action_text(nil), do: []
  defp action_text(action), do: ["", "#{action.label}:", action.url]

  defp note_text(nil), do: []
  defp note_text(note), do: ["", note]

  defp footer_text(nil), do: []
  defp footer_text(note), do: [note]

  defp assigns(spec) do
    paragraphs = List.wrap(spec[:paragraphs])

    Map.merge(theme(), %{
      heading: fetch!(spec, :heading),
      paragraphs: paragraphs,
      detail: spec[:detail],
      facts: spec[:facts] || [],
      action: spec[:action],
      note: spec[:note],
      footer_note: spec[:footer_note],
      preheader: spec[:preheader] || List.first(paragraphs) || spec[:heading],
      font_url: url(~p"/fonts/archivo-900-latin.woff2"),
      home_url: url(~p"/")
    })
  end

  defp fetch!(spec, key) do
    case Map.fetch(spec, key) do
      {:ok, value} when is_binary(value) and value != "" -> value
      _ -> raise ArgumentError, "email spec is missing a #{key}: #{inspect(spec)}"
    end
  end

  defp document(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="x-apple-disable-message-reformatting" />
        <meta name="color-scheme" content="light dark" />
        <meta name="supported-color-schemes" content="light dark" />
        <title>{@heading}</title>
        <style>
          @font-face {
            font-family: 'Archivo';
            font-style: normal;
            font-weight: 900;
            font-display: swap;
            src: url('<%= @font_url %>') format('woff2');
          }
          a { color: inherit; }
          @media (prefers-color-scheme: dark) {
            .alp-canvas { background-color: #0B0C0F !important; }
            .alp-card { background-color: #13151B !important; border-color: #F2F4F8 !important; }
            .alp-band { background-color: #060709 !important; border-color: #F2F4F8 !important; }
            .alp-text { color: #F2F4F8 !important; }
            .alp-secondary { color: #BCC2CE !important; }
            .alp-muted { color: #A1AAB9 !important; }
            .alp-rule { border-color: #282D38 !important; }
            .alp-fallback { background-color: #1B1E26 !important; border-color: #282D38 !important; }
            .alp-fact { border-color: #282D38 !important; }
            .alp-action { box-shadow: 4px 4px 0 #A3A5AD !important; }
          }
          @media only screen and (max-width: 620px) {
            .alp-shell { width: 100% !important; }
            .alp-pad { padding: 24px !important; }
            .alp-heading { font-size: 26px !important; line-height: 31px !important; }
          }
        </style>
      </head>
      <body
        class="alp-canvas"
        style={"margin:0;padding:0;width:100%;background-color:#{@canvas};-webkit-text-size-adjust:100%;"}
      >
        <!--
        THESIS: a transactional mail is the product's handwriting, not a system notice; it refuses the centered-logo pastel newsletter shell.
        OWN-WORLD: postdeploy.dev's restrained neo-brutalism, inlined: flat #FAFAFA canvas, one white card on a 2px ink border, solid ink band header with the Archivo 900 wordmark knocked out, lime CTA on ink text carrying the single hard 4px block shadow.
        FIRST VIEWPORT: ink band, then one display-weight sentence naming the one thing to do, then the lime action; nothing above the heading, no kicker, no hero image.
        SIGNATURE: the block shadow is spent once, on the action, so the only object that looks physical is the only object you can press.
        RISK: Word-engine Outlook drops the radius and the shadow; the message reads as a square bordered card there, which is the same world played flat.
        -->
        <div style={"display:none;font-size:1px;line-height:1px;max-height:0;max-width:0;opacity:0;overflow:hidden;color:#{@canvas};"}>
          {@preheader}
        </div>
        <table
          role="presentation"
          width="100%"
          cellpadding="0"
          cellspacing="0"
          border="0"
          style="border-collapse:collapse;mso-table-lspace:0pt;mso-table-rspace:0pt;"
        >
          <tr>
            <td align="center" style="padding:32px 16px 48px 16px;">
              <%!-- border-spacing:0, never border-collapse: a collapsed table
              clips a rounded, bordered cell and notches the card's top corners. --%>
              <table
                role="presentation"
                width="600"
                cellpadding="0"
                cellspacing="0"
                border="0"
                class="alp-shell"
                style="width:600px;max-width:600px;border-spacing:0;mso-table-lspace:0pt;mso-table-rspace:0pt;"
              >
                <tr>
                  <td
                    class="alp-band"
                    style={"background-color:#{@ink_band};border:2px solid #{@rule};border-bottom:none;border-radius:16px 16px 0 0;padding:20px 24px;"}
                  >
                    <a
                      href={@home_url}
                      style={"font-family:#{@display};font-size:23px;font-weight:900;letter-spacing:-0.02em;color:#{@ink_band_text};text-decoration:none;"}
                    >PostDeploy</a>
                  </td>
                </tr>
                <tr>
                  <td
                    class="alp-card alp-pad"
                    style={"background-color:#{@surface};border:2px solid #{@rule};border-top:none;border-radius:0 0 16px 16px;padding:32px;"}
                  >
                    <h1
                      class="alp-heading alp-text"
                      style={"margin:0 0 20px 0;font-family:#{@display};font-size:30px;line-height:34px;font-weight:900;letter-spacing:-0.02em;color:#{@text};"}
                    >
                      {@heading}
                    </h1>
                    <p
                      :for={paragraph <- @paragraphs}
                      class="alp-text"
                      style={"margin:0 0 16px 0;font-family:#{@sans};font-size:18px;line-height:28px;color:#{@text};"}
                    >
                      {paragraph}
                    </p>
                    <div
                      :if={@detail}
                      class="alp-fallback"
                      style={"margin:4px 0 0 0;background-color:#{@surface_2};border:1px solid #{@border};border-radius:6px;padding:12px 14px;"}
                    >
                      <span
                        class="alp-text"
                        style={"font-family:#{@mono};font-size:15px;line-height:22px;color:#{@text};word-break:break-all;"}
                      >{@detail}</span>
                    </div>
                    <table
                      :if={@facts != []}
                      role="presentation"
                      width="100%"
                      cellpadding="0"
                      cellspacing="0"
                      border="0"
                      style="margin:24px 0 0 0;border-spacing:0;"
                    >
                      <tr :for={{label, value} <- @facts}>
                        <td
                          class="alp-muted alp-fact"
                          width="140"
                          valign="top"
                          style={"width:140px;padding:9px 12px 9px 0;border-top:1px solid #{@border};font-family:#{@sans};font-size:15px;line-height:22px;color:#{@text_muted};"}
                        >
                          {label}
                        </td>
                        <td
                          class="alp-text alp-fact"
                          valign="top"
                          style={"padding:9px 0;border-top:1px solid #{@border};font-family:#{@sans};font-size:16px;line-height:22px;font-weight:600;color:#{@text};word-break:break-word;"}
                        >
                          {value}
                        </td>
                      </tr>
                    </table>
                    <table
                      :if={@action}
                      role="presentation"
                      cellpadding="0"
                      cellspacing="0"
                      border="0"
                      style="margin:28px 0 0 0;border-spacing:0;"
                    >
                      <tr>
                        <td
                          class="alp-action"
                          align="center"
                          style={"background-color:#{@accent};border:2px solid #{@rule};border-radius:10px;box-shadow:4px 4px 0 #{@rule};padding:13px 22px;"}
                        >
                          <a
                            href={@action.url}
                            style={"font-family:#{@sans};font-size:17px;line-height:22px;font-weight:600;color:#{@accent_ink};text-decoration:none;"}
                          >{@action.label}</a>
                        </td>
                      </tr>
                    </table>
                    <p
                      :if={@note}
                      class="alp-secondary"
                      style={"margin:28px 0 0 0;font-family:#{@sans};font-size:17px;line-height:26px;color:#{@text_secondary};"}
                    >
                      {@note}
                    </p>
                    <div :if={@action}>
                      <div
                        class="alp-rule"
                        style={"margin:28px 0 0 0;border-top:1px solid #{@border};"}
                      >
                      </div>
                      <p
                        class="alp-muted"
                        style={"margin:20px 0 10px 0;font-family:#{@sans};font-size:15px;line-height:22px;color:#{@text_muted};"}
                      >
                        If the button does not open, paste this link into your browser:
                      </p>
                      <div
                        class="alp-fallback"
                        style={"background-color:#{@surface_2};border:1px solid #{@border};border-radius:6px;padding:12px 14px;"}
                      >
                        <a
                          class="alp-text"
                          href={@action.url}
                          style={"font-family:#{@mono};font-size:15px;line-height:22px;color:#{@text};word-break:break-all;"}
                        >{@action.url}</a>
                      </div>
                    </div>
                  </td>
                </tr>
                <tr>
                  <td style="padding:20px 4px 0 4px;">
                    <p
                      :if={@footer_note}
                      class="alp-muted"
                      style={"margin:0 0 6px 0;font-family:#{@sans};font-size:15px;line-height:22px;color:#{@text_muted};"}
                    >
                      {@footer_note}
                    </p>
                    <p
                      class="alp-muted"
                      style={"margin:0;font-family:#{@sans};font-size:15px;line-height:22px;color:#{@text_muted};"}
                    >
                      PostDeploy is uptime monitoring, privacy-first analytics, and error tracking in one
                      product.
                      <a
                        href={@home_url}
                        style={"color:#{@text_muted};text-decoration:underline;"}
                      >postdeploy.dev</a>
                    </p>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
        </table>
      </body>
    </html>
    """
  end
end
