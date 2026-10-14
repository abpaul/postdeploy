defmodule AlplusWeb.Marketing.PackagePresenter do
  @moduledoc """
  Formats `Alplus.Billing.Package` into copy: the offer panel, the list of
  included limits, what is not included, how limits behave, and `Offer`
  structured data.

  Every number here reads through `Alplus.Billing.Package`, the same struct
  billing enforces, so the offer can never say one thing and the list
  another (BUILD.md §1, ARCHITECTURE.md §9).
  """

  alias Alplus.Billing.Package

  @doc "Dollar string from integer USD cents, e.g. `2900` -> `\"$29\"`."
  @spec dollars(non_neg_integer()) :: String.t()
  def dollars(cents), do: "$#{div(cents, 100)}"

  @doc "The package's monthly price, e.g. `\"$29\"`."
  @spec price() :: String.t()
  def price, do: dollars(Package.price_usd_cents())

  @doc "Human check-interval label, e.g. `300` -> `\"5 minutes\"`, `30` -> `\"30 seconds\"`."
  @spec interval_label(pos_integer()) :: String.t()
  def interval_label(seconds) when seconds >= 60 do
    minutes = div(seconds, 60)
    "#{minutes} minute#{if minutes > 1, do: "s", else: ""}"
  end

  def interval_label(seconds), do: "#{seconds} seconds"

  @doc "Thousands separator with no external dependency, e.g. `250_000` -> `\"250,000\"`."
  @spec thousands(non_neg_integer()) :: String.t()
  def thousands(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @doc "The monthly event ceiling as a percentage of the allowance, e.g. `\"130%\"`."
  @spec event_ceiling_percent() :: String.t()
  def event_ceiling_percent, do: "#{100 + Package.get().event_grace_percent}%"

  @doc "The offer: name, price, billing terms, eligibility, and headline limits."
  @spec offer() :: map()
  def offer do
    package = Package.get()
    l = package.limits

    %{
      id: package.id,
      name: package.name,
      price: price(),
      period: "per month",
      billing_notes: [
        "Billed monthly in USD. Tax is added at checkout where it applies.",
        "One subscription per organisation. No seat fees and nothing metered."
      ],
      eligibility: package.eligibility,
      highlights: [
        "#{l.projects} projects, #{l.members} members",
        "#{l.uptime_monitors} uptime and API monitors",
        "#{l.cron_jobs} cron and heartbeat jobs",
        check_cadence(l.min_check_interval_seconds),
        "#{thousands(div(l.analytics_events_per_month, 1000))}k analytics events a month",
        "#{thousands(div(l.error_events_per_month, 1000))}k error events a month"
      ]
    }
  end

  # "1 minute" is the interval; "every minute" is the cadence a reader hears.
  defp check_cadence(60), do: "Checks every minute"
  defp check_cadence(seconds), do: "Checks every #{interval_label(seconds)}"

  @doc "The capabilities the package includes, in display order."
  @spec features() :: [Package.feature()]
  def features, do: Package.get().features

  @doc "What the package does not include, at any price."
  @spec not_included() :: [String.t()]
  def not_included, do: Package.get().not_included

  @doc """
  How limits and billing behave, as short sentences a buyer needs before they
  decide.
  """
  @spec constraints() :: [%{id: atom(), text: String.t()}]
  def constraints do
    package = Package.get()

    [
      %{
        id: :counts,
        text:
          "Projects, members, monitors and cron jobs stop at their limit. Remove one to add another."
      },
      %{
        id: :events,
        text:
          "Monthly events are still accepted up to #{event_ceiling_percent()} of the allowance, then dropped until the month resets. Uptime and cron monitoring keep running, and nothing is billed extra."
      },
      %{
        id: :trial_end,
        text:
          "When the trial ends without a subscription, the organisation becomes read only. Its data is deleted #{package.inactive_retention_days} days later."
      },
      %{
        id: :organization,
        text: "A subscription covers one organisation. Each organisation subscribes on its own."
      }
    ]
  end

  @doc """
  Every limit the package includes, grouped by section. Only rows the backend
  enforces today appear here, with no aspirational limits.

  A row whose value is a sentence rather than a measurement carries
  `face: :prose`, so the renderer keeps it out of the mono value face.
  """
  @spec included_groups() :: [map()]
  def included_groups do
    l = Package.get().limits

    [
      %{
        title: "Organisation",
        rows: [
          %{label: "Projects", note: nil, value: "#{l.projects}"},
          %{label: "Members", note: "No per-seat fees.", value: "#{l.members}"},
          %{
            label: "Public pages",
            note: "Project-owned status and changelog pages.",
            value: "No page-count limit",
            face: :prose
          }
        ]
      },
      %{
        title: "Monitor",
        rows: [
          %{
            label: "Uptime and API monitors",
            note:
              "HTTP and HTTPS, API endpoint, keyword and response, TCP port, DNS, and SSL expiry on a monitored endpoint.",
            value: "#{l.uptime_monitors}"
          },
          %{
            label: "Cron and heartbeat jobs",
            note:
              "A scheduled job sends a start, finish or fail ping. A fail ping opens an incident and alerts you at once.",
            value: thousands(l.cron_jobs)
          },
          %{
            label: "Fastest uptime interval",
            note: nil,
            value: interval_label(l.min_check_interval_seconds)
          },
          %{
            label: "Detailed uptime samples",
            note: "Individual check results. Older results are folded into daily uptime history.",
            value: "#{l.detailed_uptime_retention_days} days"
          },
          %{
            label: "Uptime incident history",
            note: "Incident summaries and daily uptime history after detailed samples expire.",
            value: "#{l.uptime_incident_rollup_months} months"
          }
        ]
      },
      %{
        title: "Observe and Measure",
        rows: [
          %{
            label: "Analytics events per month",
            note:
              "Accepted Measure pageviews and analytics API events. Known bots, rejected payloads, retries and filtered events are not counted.",
            value: thousands(l.analytics_events_per_month)
          },
          %{
            label: "Error events per month",
            note: nil,
            value: thousands(l.error_events_per_month)
          },
          %{
            label: "Error event history",
            note: nil,
            value: "#{l.error_event_retention_days} days"
          },
          %{
            label: "Measure retention",
            note: "How long accepted pageviews and custom events remain available.",
            value: "#{l.measure_retention_days} days"
          }
        ]
      },
      %{
        title: "Alerts and access",
        rows: [
          %{
            label: "Alert channels",
            note: nil,
            value: "Email, Slack, Discord, webhook, Telegram",
            face: :prose
          },
          %{
            label: "API requests per minute",
            note: nil,
            value: thousands(l.api_rate_limit_per_minute)
          },
          %{
            label: "Audit log retention",
            note: nil,
            value: "#{l.audit_log_retention_days} days"
          }
        ]
      }
    ]
  end

  @doc "`Offer` structured data for `SoftwareApplication` JSON-LD: the package, billed monthly. The trial is never an offer."
  @spec offers() :: [map()]
  def offers do
    package = Package.get()

    [
      %{
        "@type" => "Offer",
        "name" => "#{package.name} monthly",
        "price" => "#{div(package.price.amount_usd_cents, 100)}",
        "priceCurrency" => "USD",
        "billingIncrement" => 1,
        "unitText" => "MONTH"
      }
    ]
  end

  @doc """
  The trial, rendered as the line under the subscribe action. The trial
  length comes from `Alplus.Billing.Package`, so this copy can never
  disagree with billing.
  """
  @spec trial_step() :: %{days: pos_integer(), detail: String.t()}
  def trial_step do
    days = Package.trial_days()

    %{
      days: days,
      detail:
        "No card required. The trial grants every allowance on this page. " <>
          "Subscribe before it ends to keep writing data."
    }
  end

  @doc "The call-to-action label for every public start button, trial length from the package."
  @spec cta_label() :: String.t()
  def cta_label, do: "Start your #{Package.trial_days()}-day free trial"
end
