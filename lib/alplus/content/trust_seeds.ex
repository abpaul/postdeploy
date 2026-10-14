defmodule Alplus.Content.TrustSeeds do
  @moduledoc """
  Trust pages (PRD §35): the questions a buyer asks before they integrate,
  answered from what the code actually does.

  Privacy comes first because PostDeploy sells privacy-first analytics, which makes
  our own data handling a product claim rather than a legal formality. Every
  statement here is checked against the implementation by
  `AlplusWeb.Marketing.ProductTruthTest`, and the retention numbers come from
  the same registry that enforces them.

  Deliberately not written: a security page making compliance claims. PostDeploy has
  no SOC 2, no ISO certification and no penetration test, and inventing
  reassurance is worse than admitting the gap, especially to the buyer who
  would check. What is here says what the system does and what it does not.
  """

  alias Alplus.Billing.Package
  alias Alplus.Content
  alias AlplusWeb.Marketing.PackagePresenter

  @lastmod ~D[2026-08-31]

  def run do
    Enum.each(guides(), fn attrs ->
      {:ok, _guide} =
        Content.create_guide(attrs,
          authorize?: false,
          upsert?: true,
          upsert_identity: :unique_slug,
          upsert_fields: :replace_all
        )
    end)

    :ok
  end

  defp guides, do: [privacy(), about(), terms()]

  defp privacy do
    %{
      slug: "privacy",
      path: "/privacy",
      cluster: "trust",
      intent: :informational,
      primary_query: "postdeploy privacy and data retention",
      title: "Privacy: data handling and retention | PostDeploy",
      meta_description:
        "How PostDeploy handles data: no analytics cookies, no raw IP storage, no cross-site identifiers, and one published retention schedule.",
      nav_label: "Privacy",
      summary:
        "What PostDeploy stores for each pillar, what it deliberately does not store, how visitors are counted without cookies, and how long data is kept.",
      hero_badge: "Trust",
      hero_heading: "What PostDeploy stores, and what it does not",
      hero_description:
        "PostDeploy Measure counts visitors without cookies and without storing raw IP addresses. This page states what each part of the product keeps, for how long, and what it deliberately never records. Every claim here describes the running implementation.",
      cta_heading: "See the product these rules apply to",
      cta_label: "Read what PostDeploy monitors",
      related_paths: [
        %{"path" => "/monitoring", "label" => "What PostDeploy monitors"},
        %{"path" => "/pricing", "label" => "Pricing, limits and retention"},
        %{"path" => "/", "label" => "What PostDeploy is"}
      ],
      lastmod: @lastmod,
      body_sections: [
        %{
          "heading" => "Analytics without cookies or raw IP storage",
          "body" => [
            "Measure sets no cookies, so a site running it needs no cookie banner for PostDeploy. There is no persistent visitor identifier, and no identifier that works across sites.",
            "Separating browser activity normally needs something stable about a person. Instead of storing one, PostDeploy derives a short-lived value: the project, the source, the IP address and the user agent are combined into a keyed hash, using a secret that is regenerated every day. The inputs are never written to disk. Only the hash is stored, and the raw IP address and user agent are discarded at the point of ingest.",
            "Because the key changes daily, yesterday's hash cannot be matched to today's. That is the deliberate trade: PostDeploy cannot follow a person across days, which also means PostDeploy cannot tell you a visitor returned a week later. The reporting limit and the privacy property are the same fact."
          ]
        },
        %{
          "heading" => "What each pillar stores",
          "body" => [
            "Stated per pillar, because they collect different things and a single blanket statement would be false about one of them."
          ],
          "list" => [
            "Monitor: the URL or host you asked PostDeploy to check, and the result of each check (status code, latency, error class). Monitor stores nothing about your users.",
            "Observe: the error payloads your application sends, which include stack traces and any context you attach. You control that content; if you attach personal data to an error, PostDeploy stores it.",
            "Measure: a page path, a referrer, a country derived from a request header, a browser name, and the daily visitor hash described above. Not the raw IP, not the raw user agent, not a cookie."
          ]
        },
        %{
          "heading" => "What PostDeploy never stores",
          "body" => [
            "These are absences enforced by the code, not policy promises."
          ],
          "list" => [
            "No analytics cookies, and no local storage used for identification.",
            "No raw IP addresses in analytics. The address is an input to a hash and is then discarded.",
            "No raw user-agent strings in analytics; only a derived browser name.",
            "No cross-site or cross-project identifier. The project is an input to the hash, so the same visitor on two projects is two unrelated hashes.",
            "No third-party analytics, advertising or session-replay scripts on this site or in the product."
          ]
        },
        %{
          "heading" => "How long data is kept",
          "body" => [
            "Retention is a package limit, enforced by the same code that bills you, and expired data is deleted by a scheduled job rather than left to accumulate.",
            "Detailed uptime check results are kept #{Package.limit(:detailed_uptime_retention_days)} days, after which they fold into daily uptime history. Error events are kept #{Package.limit(:error_event_retention_days)} days. Analytics rollups are kept #{Package.limit(:measure_retention_days)} days. Audit log entries are kept #{Package.limit(:audit_log_retention_days)} days.",
            "Deleting a project deletes the data belonging to it."
          ]
        },
        %{
          "heading" => "Where data is processed",
          "body" => [
            "ALPLUS TECHNOLOGIES SRL, registered in Romania, is the controller for the data described on this page.",
            "PostDeploy runs on AWS in a single region, `us-west-2`, in the United States. Cloudflare sits in front for DNS, TLS and protection against abuse. Uptime and API checks are made from those same application servers, which is why PostDeploy offers one checking region rather than a global probe network.",
            "Read the consequence plainly: if your visitors are in the European Union, the analytics PostDeploy records about them is processed in the United States. PostDeploy stores no cookie, no raw IP and no persistent visitor identifier, which narrows what crosses, but the processing location is what it is.",
            "Analytics telemetry for recent windows is also written to Cloudflare Analytics Engine; durable aggregates and all authoritative state live in the PostDeploy database."
          ]
        },
        %{
          "heading" => "What this page does not claim",
          "body" => [
            "PostDeploy holds no SOC 2 report, no ISO certification, and has not commissioned an external penetration test. If your procurement process requires any of those, PostDeploy does not meet it today, and saying so is more useful than a page of reassuring language.",
            "One person operates PostDeploy. Treat the operational maturity accordingly when deciding what to depend on it for."
          ]
        }
      ],
      faqs: [
        %{
          "q" => "Do I need a cookie banner to use PostDeploy Measure?",
          "a" =>
            "PostDeploy sets no cookies and stores no persistent identifier, so PostDeploy itself does not create that requirement. Whether your site needs a banner depends on everything else running on it and on your jurisdiction, which is a question for your own advisers rather than for us."
        },
        %{
          "q" => "Can PostDeploy tell me if a visitor came back next week?",
          "a" =>
            "No. The key used to derive the visitor hash is regenerated daily, so a visitor cannot be matched across days. That limitation is the mechanism that makes the analytics privacy-preserving."
        },
        %{
          "q" => "Does PostDeploy store my users' IP addresses?",
          "a" =>
            "Not in analytics. The IP address is one input to a keyed hash and is discarded at ingest; it is never written to storage. Error payloads are different: they contain whatever your application chooses to send, which is under your control."
        },
        %{
          "q" => "Is PostDeploy SOC 2 certified?",
          "a" =>
            "No. There is no SOC 2 report, no ISO certification and no external penetration test. If your review requires one, PostDeploy does not meet that bar today."
        }
      ]
    }
  end

  defp about do
    %{
      slug: "about",
      path: "/about",
      cluster: "trust",
      intent: :informational,
      primary_query: "postdeploy about",
      title: "About PostDeploy: one toolkit, not three | PostDeploy",
      meta_description:
        "What PostDeploy is for, what it covers in one project, and who builds and runs it: Paul Bădărău, the founder and only operator.",
      nav_label: "About",
      summary:
        "What PostDeploy is for, what it covers in one project, and who builds and runs it.",
      hero_badge: "About PostDeploy",
      hero_heading: "One person builds and runs PostDeploy",
      hero_description:
        "PostDeploy is production monitoring for developers who ship their own software. Paul Bădărău builds it and runs the service.",
      cta_heading: "Try it on a project you already run",
      cta_label: "Start your #{Package.trial_days()}-day free trial",
      related_paths: [
        %{"path" => "/alternatives", "label" => "Compare PostDeploy with the tools it replaces"}
      ],
      lastmod: @lastmod,
      body_sections: [
        %{"founder_letter" => true},
        %{
          "heading" => "What PostDeploy is for",
          "body" => [
            "PostDeploy is for solo developers and small teams who ship and run their own production software.",
            "Your coding agent sets up the monitoring for a project. You review it in the dashboard, and it stays together under one login at one flat price."
          ]
        },
        %{
          "heading" => "What one project gets",
          "list" => [
            "Uptime checks: HTTP, keyword, TCP and DNS, with SSL and domain expiry warnings.",
            "Cron heartbeats: start, finish and fail pings from your scheduled jobs.",
            "Error tracking: errors grouped into issues, with releases and sourcemaps.",
            "Cookieless web analytics and product analytics from your own app.",
            "A public status page and a changelog."
          ]
        }
      ],
      faqs: [
        %{
          "q" => "Will PostDeploy still be here next year?",
          "a" =>
            "No small product can promise that. Leaving costs minutes: a heartbeat is one curl line, analytics is one script tag, and errors go to a standard Sentry DSN that you point somewhere else. The trial needs no credit card."
        }
      ]
    }
  end

  defp terms do
    %{
      slug: "terms",
      path: "/terms",
      cluster: "trust",
      intent: :informational,
      primary_query: "postdeploy terms of service",
      title: "Terms of service | PostDeploy",
      meta_description:
        "PostDeploy terms of service: trial, billing, package allowances, account deletion, and no promised service level.",
      nav_label: "Terms",
      summary:
        "What PostDeploy is, how the trial and the subscription work, what happens when a trial or subscription ends, what happens when you go over an allowance, account and data deletion, and that no service level is promised.",
      hero_badge: "Trust",
      hero_heading: "Terms of service",
      hero_description:
        "ALPLUS TECHNOLOGIES SRL provides PostDeploy and takes payment through Stripe for its subscription, which is why this page exists. It states in plain terms what the service is, how the free trial works, how paid billing works, and what PostDeploy does not promise.",
      related_paths: [
        %{"path" => "/pricing", "label" => "Pricing and allowances"},
        %{"path" => "/privacy", "label" => "How PostDeploy handles data"}
      ],
      lastmod: @lastmod,
      body_sections: [
        %{
          "heading" => "Who provides the service",
          "body" => [
            "ALPLUS TECHNOLOGIES SRL provides PostDeploy. The company is registered in Romania under registration number 55013997.",
            "Write to hello@alplustech.com with any question about these terms, about billing, or about your account."
          ]
        },
        %{
          "heading" => "What the service is",
          "body" => [
            "PostDeploy is a monitoring and analytics service: uptime and API checks, cron job heartbeats, error tracking, and cookieless website analytics, run under one account per organisation."
          ]
        },
        %{
          "heading" => "The free trial",
          "body" => [
            "Every new organisation starts with a #{Package.trial_days()}-day free trial. The trial needs no credit card, and PostDeploy creates no Stripe objects for it: no card, no customer, no subscription.",
            "The trial includes every PostDeploy allowance. When the #{Package.trial_days()} days end without a subscription, the organisation becomes read-only: existing monitors, incidents, errors and charts stay visible, but writes and data ingest stop until you subscribe."
          ]
        },
        %{
          "heading" => "Subscription",
          "body" => [
            "PostDeploy bills #{PackagePresenter.price()} a month per organisation, charged through Stripe. There is one package and one monthly cadence, and Stripe processes the recurring charge; PostDeploy does not store your card details. Subscribing at any point, during or after the trial, restores full write access and keeps everything you configured."
          ]
        },
        %{
          "heading" => "Data retention after expiry",
          "body" => [
            "If an organisation stays inactive for more than #{Package.inactive_retention_days()} days after its access ends, PostDeploy deletes its collected project data: analytics rollups, monitor check history and error events. The organisation account, its users and its billing history are kept, so subscribing later starts from a clean data slate but the same account."
          ]
        },
        %{
          "heading" => "Allowances",
          "body" => [
            "The package has allowances: a limit on monitors, cron jobs, analytics events and similar counts. Reaching an allowance blocks the next create for that resource until you remove one. It does not appear on your bill as an added charge."
          ]
        },
        %{
          "heading" => "Accounts and data",
          "body" => [
            "You can delete your account. Deleting an account deletes the data belonging to it, including its projects, checks, error events and analytics history."
          ]
        },
        %{
          "heading" => "No service level is promised",
          "body" => [
            "PostDeploy does not promise a guaranteed level of uptime, response time or support turnaround for the service itself. If your use of PostDeploy depends on such a guarantee, PostDeploy does not provide one today.",
            "PostDeploy may update these terms. Continuing to use the service after an update means you accept the change."
          ]
        },
        %{
          "heading" => "Governing law",
          "body" => [
            "Romanian law governs these terms, because ALPLUS TECHNOLOGIES SRL is registered in Romania.",
            "Nothing on this page removes a right you hold as a consumer under Romanian or European Union law."
          ]
        }
      ],
      faqs: [
        %{
          "q" => "What happens after the #{Package.trial_days()} days?",
          "a" =>
            "Without a subscription the organisation becomes read-only: you keep seeing every chart, incident and error, but writes and ingest stop. Data is kept for #{Package.inactive_retention_days()} more days and then purged. Subscribing at any point restores everything."
        },
        %{
          "q" => "What happens if I go over an allowance?",
          "a" =>
            "The next create for that resource is blocked until you remove one. Existing monitors, jobs and data keep working; nothing is billed automatically."
        }
      ]
    }
  end
end
