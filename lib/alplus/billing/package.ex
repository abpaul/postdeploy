defmodule Alplus.Billing.Package do
  @moduledoc """
  The one PostDeploy package (ARCHITECTURE.md §11, BUILD.md §1).

  This struct is the single source of truth for what a customer buys: the
  name, the price and billing interval, the trial, who the package is for,
  every enforced limit, the included capabilities, and what is not offered.
  Billing, entitlement checks, retention jobs, the pricing page, the console,
  and the public product facts all read it. Do not copy a value out of it.

  There is no plan ladder. An organization is either in its trial or
  subscribed, and both states grant the same limits. `Alplus.Billing.Access`
  decides which state applies.

  Money is integer USD cents, never a float.
  """

  @type limit_key ::
          :projects
          | :members
          | :uptime_monitors
          | :cron_jobs
          | :min_check_interval_seconds
          | :detailed_uptime_retention_days
          | :error_event_retention_days
          | :artifact_retention_days
          | :uptime_incident_rollup_months
          | :analytics_events_per_month
          | :error_events_per_month
          | :product_events_per_month
          | :product_event_retention_days
          | :measure_retention_days
          | :api_rate_limit_per_minute
          | :audit_log_retention_days
          | :goals_per_project

  @type price :: %{
          amount_usd_cents: pos_integer(),
          interval: :month,
          stripe_lookup_key: String.t(),
          tax: :exclusive
        }

  @type trial :: %{days: pos_integer(), card_required: boolean()}

  @type feature :: %{id: atom(), name: String.t(), description: String.t()}

  @type t :: %__MODULE__{
          id: :postdeploy,
          name: String.t(),
          price: price(),
          trial: trial(),
          billed_per: :organization,
          eligibility: String.t(),
          limits: %{limit_key() => pos_integer()},
          event_grace_percent: pos_integer(),
          inactive_retention_days: pos_integer(),
          features: [feature()],
          not_included: [String.t()]
        }

  @enforce_keys [
    :id,
    :name,
    :price,
    :trial,
    :billed_per,
    :eligibility,
    :limits,
    :event_grace_percent,
    :inactive_retention_days,
    :features,
    :not_included
  ]
  defstruct @enforce_keys

  # A plain map, because a module cannot build its own struct at compile
  # time. `get/0` returns it as the struct.
  @package %{
    id: :postdeploy,
    name: "PostDeploy",
    price: %{
      amount_usd_cents: 2_900,
      interval: :month,
      stripe_lookup_key: "postdeploy_monthly_usd",
      tax: :exclusive
    },
    trial: %{days: 14, card_required: false},
    billed_per: :organization,
    eligibility:
      "For developers and small teams running production software in one organisation.",
    limits: %{
      projects: 10,
      members: 5,
      uptime_monitors: 100,
      cron_jobs: 200,
      min_check_interval_seconds: 60,
      detailed_uptime_retention_days: 30,
      error_event_retention_days: 30,
      artifact_retention_days: 60,
      uptime_incident_rollup_months: 24,
      analytics_events_per_month: 500_000,
      error_events_per_month: 50_000,
      product_events_per_month: 100_000,
      # Product analytics answers every V1 question from raw events, so the
      # raw window is the analysis window (ADR 0007). Funnels and retention
      # cannot look further back than this.
      product_event_retention_days: 90,
      measure_retention_days: 730,
      api_rate_limit_per_minute: 300,
      audit_log_retention_days: 90,
      # The `goals` table trigger refuses a 51st goal per project, so the
      # package cannot promise more.
      goals_per_project: 50
    },
    # `Alplus.Billing.EventMeter` keeps accepting monthly events up to this
    # percentage above the limit, then drops them until the month resets.
    event_grace_percent: 30,
    inactive_retention_days: 30,
    features: [
      %{
        id: :monitor,
        name: "Uptime and API monitoring",
        description: "HTTP, keyword, TCP and DNS checks, with SSL and domain expiry warnings."
      },
      %{
        id: :heartbeats,
        name: "Cron and heartbeat monitoring",
        description:
          "Start, finish and fail pings. A fail ping opens an incident and alerts you at once."
      },
      %{
        id: :observe,
        name: "Error tracking",
        description: "Grouping, triage, releases, source maps and release health."
      },
      %{
        id: :measure,
        name: "Cookieless web analytics",
        description: "Pageviews, visits and custom events with no cookies and no raw IP."
      },
      %{
        id: :public_pages,
        name: "Status pages and changelogs",
        description: "One public page per project, with no page-count limit."
      },
      %{
        id: :alerts,
        name: "Alerts",
        description: "Email, Slack, Discord, webhook and Telegram."
      },
      %{
        id: :product_analytics,
        name: "Product analytics",
        description: "Events, funnels, activation and retention from one write-only key."
      },
      %{
        id: :mcp,
        name: "MCP and API access",
        description: "Connect a coding agent to set up and read every tool."
      }
    ],
    not_included: [
      "Logs",
      "Tracing and APM",
      "Session replay",
      "SSO and SAML",
      "Browser checks",
      "Multi-region checks",
      "SMS and voice alerts"
    ]
  }

  @doc "Returns the package."
  @spec get() :: t()
  def get, do: struct!(__MODULE__, @package)

  @doc "Returns one limit. Raises on an unknown key: the limit set is closed."
  @spec limit(limit_key()) :: pos_integer()
  def limit(key), do: Map.fetch!(@package.limits, key)

  @doc "Returns the trial length in days."
  @spec trial_days() :: pos_integer()
  def trial_days, do: @package.trial.days

  @doc "Returns the monthly price in USD cents."
  @spec price_usd_cents() :: pos_integer()
  def price_usd_cents, do: @package.price.amount_usd_cents

  @doc "Returns the Stripe lookup key of the package's price."
  @spec stripe_lookup_key() :: String.t()
  def stripe_lookup_key, do: @package.price.stripe_lookup_key

  @doc "Returns how long data is kept after an organization loses access."
  @spec inactive_retention_days() :: pos_integer()
  def inactive_retention_days, do: @package.inactive_retention_days

  @doc "Returns the monthly event count past which new events are dropped."
  @spec event_ceiling(pos_integer()) :: pos_integer()
  def event_ceiling(limit), do: div(limit * (100 + @package.event_grace_percent), 100)
end
