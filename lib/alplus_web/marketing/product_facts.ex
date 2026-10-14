defmodule AlplusWeb.Marketing.ProductFacts do
  @moduledoc """
  Versioned public product facts for people and machine-readable marketing
  surfaces.

  Numeric package limits always come from `Alplus.Billing.Package`, which
  billing enforces. This module owns the separately reviewed marketing facts that do not
  live in billing: product definition, release stage, pillar availability, and
  explicitly excluded capabilities.

  Do not add a literal package number here. Add it to `Alplus.Billing.Package`,
  then select it through `@public_limit_keys` when it is a supported public
  offer.
  Public pages are project-owned and have no page-count limit. Goal limits
  remain excluded until Measure evaluates and displays goal conversions.
  """

  alias Alplus.Billing.Package
  alias AlplusWeb.Marketing.PackagePresenter

  # 1.3.0 changed two enumerated values a consumer may switch on:
  # `release_stage` and every pillar `availability`. PostDeploy is no longer gated
  # behind a waitlist, because `/register` creates the account and signs the
  # reader in.
  #
  # 1.5.0 adds annual prices and the 14-day trial contract. The configured
  # 1.6.0 makes Public pages a project-owned surface without a page-count cap.
  # trial remains a lifecycle field, never an entry in `plans`.
  #
  # 2.0.0 replaces Indie, Pro and Scale with one `postdeploy` plan billed
  # monthly. `plans` holds one entry, the annual pricing fields are gone, the
  # alert-channel booleans are gone (every channel is included), and
  # `lifecycle.after_trial` names the one plan.
  #
  # 3.0.0 replaces the `plans` list with one `package` object that also
  # carries eligibility, included features, and exclusions. The trial no
  # longer names a plan id: `lifecycle.trial.limits` is `"package"`, and
  # `lifecycle.after_trial` is gone.
  #
  # 4.0.0 adds the Analytics pillar and its `analytics` object, adds two
  # public limits, and renames two limit labels so "analytics events" no
  # longer means two different meters. Funnels moved from excluded to
  # shipped.
  @version "4.0.0"

  # The date a human last checked every non-plan claim in this module against
  # the code paths named in the comments below. Bump it when you re-verify.
  @last_verified "2026-09-17"

  @public_limit_keys [
    :projects,
    :members,
    :uptime_monitors,
    :cron_jobs,
    :min_check_interval_seconds,
    :detailed_uptime_retention_days,
    :uptime_incident_rollup_months,
    :analytics_events_per_month,
    :product_events_per_month,
    :error_events_per_month,
    :measure_retention_days,
    :product_event_retention_days,
    :api_rate_limit_per_minute,
    :audit_log_retention_days
  ]

  @limit_labels %{
    projects: "Projects",
    members: "Members",
    uptime_monitors: "Uptime and API monitors",
    cron_jobs: "Cron and heartbeat jobs",
    min_check_interval_seconds: "Minimum check interval in seconds",
    detailed_uptime_retention_days: "Detailed uptime retention in days",
    uptime_incident_rollup_months: "Uptime incident rollup retention in months",
    analytics_events_per_month: "Web analytics events per month",
    product_events_per_month: "Product analytics events per month",
    error_events_per_month: "Error events per month",
    measure_retention_days: "Measure retention in days",
    product_event_retention_days: "Product analytics event retention in days",
    api_rate_limit_per_minute: "API requests per minute",
    audit_log_retention_days: "Audit log retention in days"
  }

  @doc "The public facts contract version. Bump it when this structure changes."
  @spec version() :: String.t()
  def version, do: @version

  @doc "Returns the complete versioned, machine-readable product facts map."
  @spec facts() :: map()
  def facts do
    %{
      "version" => version(),
      "product" => %{
        "name" => "PostDeploy",
        "release_stage" => "generally_available",
        "definition" =>
          "PostDeploy is a project-based reliability toolkit for small software teams.",
        "pillars" => [
          %{
            "name" => "Monitor",
            "description" => "Uptime, API, and cron-job heartbeat monitoring.",
            "availability" => "live"
          },
          %{
            "name" => "Observe",
            "description" => "Error tracking with grouping, triage, releases, and alerts.",
            "availability" => "live"
          },
          %{
            "name" => "Measure",
            "description" => "Cookieless web analytics with pageviews and visits.",
            "availability" => "live"
          },
          %{
            "name" => "Analytics",
            "description" =>
              "Product analytics: events, funnels, activation and retention from anonymous identifiers.",
            "availability" => "live"
          }
        ],
        "not_offered" => [
          %{
            "name" => "Goal tracking",
            "reason" =>
              "Goal resources and capacity exist, but PostDeploy does not yet evaluate or display goal conversions."
          },
          %{
            "name" => "Logs",
            "reason" => "PostDeploy does not ingest, store or display logs."
          }
        ]
      },
      "package" => package_facts(),
      "lifecycle" => lifecycle_facts(),
      "monitor" => monitor_facts(),
      "observe" => observe_facts(),
      "measure" => measure_facts(),
      "analytics" => analytics_facts(),
      "privacy" => privacy_facts(),
      "sdks" => sdk_facts(),
      "last_verified" => @last_verified
    }
  end

  # Every value below is a claim the code must support. The product identity
  # and live pillar claims trace to `AlplusWeb.Router`'s public routes and the
  # corresponding seeded pages in `Alplus.Content.Seeds`.
  # When one of these values changes in the product, change it here and the
  # consistency tests will point at the public copy that still disagrees.
  # The trial is a lifecycle stage with its own duration, published apart
  # from `package` so a consumer cannot mistake it for something to buy. The
  # trial grants the package's limits, and no card is required to start it.
  defp lifecycle_facts do
    package = Package.get()

    %{
      "trial" => %{
        "days" => package.trial.days,
        "card_required" => package.trial.card_required,
        "limits" => "package",
        "data_retention_after_expiry_days" => package.inactive_retention_days
      }
    }
  end

  # `Alplus.Monitoring.Monitor`'s `monitors_type_check` constraint is the
  # authority for check types; monitor configuration workflows prove each one
  # is user-creatable rather than merely storable.
  defp monitor_facts do
    %{
      "check_types" => ["http", "keyword", "tcp", "dns", "heartbeat"],
      "not_offered" => ["icmp_ping", "udp", "browser_checks", "multi_region_checks"],
      # `Alplus.Monitoring.HttpExecutor` runs in the Phoenix application, so
      # checks originate from the one deployed location.
      "check_regions" => 1,
      # `Alplus.Monitoring.Heartbeat.accept/2`.
      "heartbeat_states" => ["start", "finish", "fail"],
      "heartbeat_hung_run_detection" => true,
      # `Alplus.Monitoring.ExpiryScan`, default thresholds 14/7/1 days.
      "ssl_and_domain_expiry_warnings" => true,
      # `Alplus.Notifications.Channel`'s type CHECK constraint.
      "alert_channels" => ["email", "slack", "discord", "webhook", "telegram"]
    }
  end

  # `Alplus.Observe.Ingest.write_items/3` writes grouped issues through
  # `Alplus.Observe.EventWriter`; releases and artifacts are represented by
  # `Alplus.Observe.Release` and `Alplus.Observe.ReleaseArtifact`.
  # `Alplus.Observe.Symbolicator.symbolicate/3` resolves uploaded sourcemaps.
  #
  # `AlplusWeb.SentryIngestController` accepts the error events a Sentry client
  # posts to its DSN. Other envelope item types are skipped.
  defp observe_facts do
    %{
      "availability" => "live",
      "error_tracking" => true,
      "grouping" => true,
      "releases_and_artifacts" => true,
      "sourcemap_symbolication" => true,
      "sentry_client_ingest" => true
    }
  end

  defp measure_facts do
    %{
      "availability" => "live",
      # `Alplus.Measure.Ingest.record/7` counts accepted pageviews and custom
      # events only. Goals are not evaluated at ingest.
      "counted_events" => ["pageview", "custom_event"],
      "goal_conversions" => false
    }
  end

  # `Alplus.Analytics.Queries` computes each of these from the raw event
  # table; `Alplus.Analytics.Limits` owns every published bound.
  defp analytics_facts do
    %{
      "availability" => "live",
      "ingest_endpoints" => ["/v1/events", "/v1/events/batch"],
      "max_events_per_batch" => Alplus.Analytics.Limits.batch_max_events(),
      "max_properties_per_event" => Alplus.Analytics.Limits.property_max_count(),
      "funnels" => true,
      "activation" => true,
      "retention" => true,
      "identity_merging" => false,
      "session_replay" => false,
      "feature_flags" => false,
      "experiment_engine" => false
    }
  end

  # `Alplus.Measure.VisitorHash` HMACs the project, source, IP and user agent
  # under a salt that rotates daily (`Alplus.Measure.VisitorSalt`), and
  # `Alplus.Measure.Ingest.annotate/3` drops the raw IP and user agent.
  defp privacy_facts do
    %{
      "cookies" => false,
      "stores_raw_ip" => false,
      "persistent_visitor_identifiers" => false,
      "visitor_identification" => "daily-rotating salted HMAC, not reversible across days"
    }
  end

  # Availability here means "a reader can install it today", not "the source
  # exists in our monorepo". The JavaScript, Elixir, and Ruby SDKs are
  # published and keep working against the same ingest host, but the preferred
  # integration is a Sentry client pointed at an Observe key (`observe` facts
  # above). The legacy `alplus` package names still resolve and are never
  # published as facts.
  #
  # Registry verification:
  #   npm @postdeploy/sdk    -> 0.5.0 (2026-09-18)
  #   hex postdeploy_sdk     -> 0.2.0 (2026-09-18)
  #   rubygems postdeploy    -> 0.2.0 (2026-09-18)
  #
  # `AlplusWeb.Marketing.ProductTruthTest` pins this installable contract.
  defp sdk_facts do
    %{
      "javascript" => %{
        "package" => "@postdeploy/sdk",
        "registry" => "npm",
        "availability" => "published"
      },
      "elixir" => %{
        "package" => "postdeploy_sdk",
        "registry" => "hex",
        "availability" => "published"
      },
      "ruby" => %{
        "package" => "postdeploy",
        "registry" => "rubygems",
        "availability" => "published"
      }
    }
  end

  @doc "Renders the same public facts as concise Markdown pricing data."
  @spec pricing_markdown() :: String.t()
  def pricing_markdown do
    facts = facts()

    [
      "# PostDeploy pricing",
      "",
      "Contract version: #{facts["version"]}",
      "",
      "Release stage: generally available. Monitor, Observe, Measure, and Public pages are live.",
      "",
      "Every account starts on a #{Package.trial_days()}-day free trial. No card required. Then one package: #{PackagePresenter.price()}/month, billed monthly.",
      "",
      "Public pages belong to projects and have no page-count limit. Goal tracking is not yet available.",
      "",
      "## Package",
      "",
      package_markdown(facts["package"])
    ]
    |> List.flatten()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp package_facts do
    package = Package.get()

    %{
      "id" => Atom.to_string(package.id),
      "name" => package.name,
      "eligibility" => package.eligibility,
      "billed_per" => Atom.to_string(package.billed_per),
      "pricing" => %{
        "currency" => "USD",
        "billing_period" => Atom.to_string(package.price.interval),
        "price_usd_cents" => package.price.amount_usd_cents,
        "tax" => Atom.to_string(package.price.tax)
      },
      "limits" =>
        Map.new(@public_limit_keys, fn key ->
          {Atom.to_string(key), Map.fetch!(package.limits, key)}
        end),
      "monthly_event_ceiling_percent" => 100 + package.event_grace_percent,
      "features" =>
        Enum.map(package.features, fn feature ->
          %{
            "id" => Atom.to_string(feature.id),
            "name" => feature.name,
            "description" => feature.description
          }
        end),
      "not_included" => package.not_included
    }
  end

  defp package_markdown(package) do
    pricing = package["pricing"]

    price_line = "* Price: #{PackagePresenter.dollars(pricing["price_usd_cents"])}/month"

    limit_lines =
      Enum.map(@public_limit_keys, fn key ->
        "* #{Map.fetch!(@limit_labels, key)}: #{package["limits"][Atom.to_string(key)]}"
      end)

    feature_lines = Enum.map(package["features"], &"* Includes: #{&1["name"]}")
    excluded_line = "* Not included: #{Enum.join(package["not_included"], ", ")}"

    Enum.join(
      ["### #{package["name"]}", package["eligibility"], price_line] ++
        limit_lines ++ feature_lines ++ [excluded_line],
      "\n"
    )
  end
end
