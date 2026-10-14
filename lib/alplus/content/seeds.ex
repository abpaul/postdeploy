defmodule Alplus.Content.Seeds do
  @moduledoc """
  Seeds the real marketing content ported from `workers/www` (BUILD.md
  Phase 4): the home and pricing pages, the alternatives index, the two
  pillar guides, and every competitor comparison in
  `workers/www/site/lib/competitors.ts`.

  Idempotent: every create uses `upsert?: true` on the resource's unique
  slug identity, so running `run/0` twice updates the same rows instead of
  duplicating them. Called with `authorize?: false` throughout — this is
  the one script allowed to write `Alplus.Content` directly (see
  `Alplus.Content` moduledoc).
  """

  alias Alplus.Billing.Package
  alias Alplus.Content
  alias AlplusWeb.Marketing.PackagePresenter

  @lastmod ~D[2026-08-03]
  @author "Paul"

  def run do
    seed_pages()
    seed_guides()
    seed_comparisons()
    # The monitoring cluster and high-intent guides live in their own module
    # to keep each readable; they seed the same `Guide` resource.
    Alplus.Content.MonitoringSeeds.run()
    Alplus.Content.ObserveSeeds.run()
    Alplus.Content.MeasureSeeds.run()
    Alplus.Content.EditorialSeeds.run()
    Alplus.Content.TrustSeeds.run()
    Alplus.Content.DocsSeeds.run()
    Alplus.Content.ArticleSeeds.run()
    :ok
  end

  # -- Pages ------------------------------------------------------------

  defp seed_pages do
    Enum.each(pages(), fn attrs ->
      {:ok, _page} =
        Content.create_page(attrs,
          authorize?: false,
          upsert?: true,
          upsert_identity: :unique_slug,
          upsert_fields: :replace_all
        )
    end)
  end

  defp pages do
    entry = Package.get().limits
    # Package figures on public pages come from `PackagePresenter` at render
    # time (package card, price band); the pricing FAQ literals are guarded by
    # ProductTruthTest against the package in both directions.

    [
      %{
        slug: "home",
        path: "/",
        cluster: "home",
        intent: :navigational,
        primary_query: "postdeploy",
        title: "Production monitoring for the project you just shipped | PostDeploy",
        meta_description:
          "Uptime checks, cron heartbeats, error tracking and cookieless analytics in one project. Connect your coding agent, say what to watch, and review what it created.",
        og_title: "PostDeploy: production monitoring your coding agent sets up",
        og_description:
          "Uptime, cron, errors and analytics for the project you just shipped. One login, one flat price, a #{Package.trial_days()}-day free trial.",
        nav_label: "Home",
        summary:
          "PostDeploy is production monitoring for solo developers and small teams: uptime checks, cron heartbeats, error tracking and cookieless analytics in one project, set up by your coding agent.",
        hero_heading: "Production monitoring for the project you just shipped.",
        group: "core",
        priority: "1.0",
        lastmod: ~D[2026-08-31],
        body_sections: [
          %{
            "slug" => "included",
            "heading" => "What you get in each project",
            "body" => [
              "Each project holds the same set of tools under one login and one flat price per organisation."
            ],
            "list" => [
              "Uptime checks: HTTP, keyword, TCP and DNS, with SSL and domain expiry warnings.",
              "Cron heartbeats: start, finish and fail pings from your scheduled jobs.",
              "Error tracking: errors grouped into issues, with releases and sourcemaps.",
              "Cookieless web analytics: pageviews and custom events, with no cookies and no raw IP stored.",
              "Product analytics: events, funnels, activation and retention from your own app.",
              "A public status page and a changelog."
            ]
          },
          %{
            "slug" => "setup",
            "heading" => "How setup works",
            "body" => [
              "Connect your coding agent to PostDeploy over MCP. In the browser you approve what it can read and change.",
              "Then say what to watch. The agent creates the monitors, sources and keys, and you review them in the dashboard."
            ],
            "steps" => [
              "Connect your coding agent and approve access in the browser.",
              "Tell it what to watch: your site, a nightly job, your errors.",
              "Review the monitors and keys it created."
            ],
            "code" =>
              "# Report the job's exit code: 0 records a finish, any other value records a fail.\n0 3 * * * /usr/local/bin/backup.sh; curl -fsS https://ingest.postdeploy.dev/h/hb_YOUR_TOKEN/$?",
            "after" => [
              "After setup, your project calls plain endpoints. A scheduled job runs one curl line. Your app sends errors from a Sentry client. Your pages load one script tag.",
              "Set the DSN of your Sentry client to `https://<key>@ingest.postdeploy.dev/1`, with the key your agent creates."
            ]
          },
          %{
            "slug" => "start",
            "heading" => "Start with the project you just shipped",
            "body" => [
              "The #{Package.trial_days()}-day free trial needs no card. Connect your agent, say what to watch, and review the result."
            ]
          }
        ],
        faqs: []
      },
      %{
        slug: "pricing",
        path: "/pricing",
        cluster: "pricing",
        intent: :transactional,
        primary_query: "postdeploy pricing",
        title:
          "Pricing: #{Package.trial_days()}-day free trial, then #{PackagePresenter.price()} a month | PostDeploy",
        meta_description:
          "Try PostDeploy free for #{Package.trial_days()} days, no card. Then one package at #{PackagePresenter.price()} a month per organisation for uptime, cron, analytics, and errors.",
        og_title:
          "PostDeploy pricing: a #{Package.trial_days()}-day free trial, then one package at #{PackagePresenter.price()} a month",
        og_description:
          "Uptime, cron, analytics and error tracking organised around the same projects. Try PostDeploy free for #{Package.trial_days()} days, no card required. Then keep using it for #{PackagePresenter.price()} a month.",
        nav_label: "Pricing",
        summary:
          "PostDeploy's one package and its enforced allowances: a #{Package.trial_days()}-day free trial with no card, then #{PackagePresenter.price()} a month, with the full list of what is included and a pricing FAQ.",
        hero_badge: "#{Package.trial_days()}-day free trial, no card",
        hero_heading: "One flat price per organisation.",
        hero_description:
          "Uptime checks, cron heartbeats, error tracking and cookieless analytics share one package. Try every feature free for #{Package.trial_days()} days, with no card. Then pay #{PackagePresenter.price()} a month per organisation.",
        group: "core",
        priority: "1.0",
        lastmod: ~D[2026-08-31],
        body_sections: [
          %{
            "heading" => "Your coding agent sets it up",
            "body" => [
              "Connect a coding agent to PostDeploy over MCP. It creates the monitors, heartbeats, error sources and analytics keys, and you review them in the dashboard.",
              "You approve its access in the browser when you connect it. After setup, your code calls plain endpoints: a curl heartbeat URL, a Sentry DSN or a script tag."
            ]
          }
        ],
        faqs: [
          %{
            "q" => "What does PostDeploy cost?",
            "a" =>
              "#{PackagePresenter.price()} a month per organisation, billed monthly. There are no per-seat fees, no meters, no annual contract and nothing added to the invoice."
          },
          %{
            "q" => "Who is PostDeploy for?",
            "a" =>
              "Solo developers, indie founders and small teams who run their own production software. One organisation holds up to #{entry.members} members and #{entry.projects} projects, so a small team or a small agency fits in one."
          },
          %{
            "q" => "Do I need a coding agent?",
            "a" =>
              "A coding agent connected over MCP creates the monitors, heartbeats, error sources and analytics keys, and you review them in the dashboard. You create the organisation in the dashboard. Projects can come from you or from your agent. The free website health check can also start a continuous URL check without an agent. After setup, no agent runs in production: your code calls a heartbeat URL, an SDK or a script tag."
          },
          %{
            "q" => "What happens after the #{Package.trial_days()} days?",
            "a" =>
              "Without a subscription the organisation becomes read-only. Existing charts, incidents and errors stay visible, but you cannot add or change data. PostDeploy keeps that data for #{Package.inactive_retention_days()} more days, then deletes it. Subscribe during that window to keep working with the same data. After deletion, the account remains but the collected data does not come back."
          },
          %{
            "q" => "What counts as an uptime monitor?",
            "a" =>
              "One polled check: HTTP, keyword, TCP or DNS. SSL and domain expiry warnings (14, 7 and 1 days before expiry) come with a monitored endpoint and use no extra slot. Heartbeats count as cron jobs, not uptime monitors."
          },
          %{
            "q" => "What counts as a cron job?",
            "a" =>
              "One scheduled job watched with a heartbeat URL. The job can send a start, a finish or a fail ping. A fail ping opens an incident at once and alerts your channels. A run that started and never finished is detected as hung when the next ping arrives, if the monitor has an expected duration. A run that never starts sends nothing, so PostDeploy cannot report it. A job on an interval schedule shows as Late on the Monitor screen. Cron jobs have their own allowance, so watching a job never uses an uptime monitor."
          },
          %{
            "q" => "What counts as an analytics event?",
            "a" =>
              "Accepted pageviews and custom events. Known bots, rejected payloads, retries and filtered events are not counted against your allowance."
          },
          %{
            "q" => "How long is data kept?",
            "a" =>
              "Detailed uptime samples, meaning individual check results, are kept for #{entry.detailed_uptime_retention_days} days. Beyond that window checks are folded into daily uptime history rather than kept sample by sample."
          },
          %{
            "q" => "What happens if I go over an allowance?",
            "a" =>
              "Adding a monitor, cron job, project or member past its limit is blocked until you remove one. It never appears as an extra charge. Monitors and jobs you already have keep running. PostDeploy accepts analytics and error events up to #{Package.get().event_grace_percent}% above the monthly allowance. Events beyond that ceiling are not stored or billed."
          },
          %{
            "q" => "What does PostDeploy not do?",
            "a" =>
              "PostDeploy has no on-call rotations, no SMS or voice alerts, no logs, no tracing or APM, no session replay and no browser or multi-region checks. It tells you what broke and when, on email, Slack, Discord, webhook and Telegram, including during the trial."
          },
          %{
            "q" => "Where do the checks run from?",
            "a" =>
              "From one location, the PostDeploy application servers. A failure is not confirmed from a second location, so a network problem between that location and your server can read as downtime."
          }
        ]
      },
      %{
        slug: "alternatives",
        path: "/alternatives",
        cluster: "comparison",
        intent: :commercial_investigation,
        primary_query: "monitoring tool comparisons",
        title: "Monitoring and analytics alternatives compared | PostDeploy",
        meta_description:
          "Compare PostDeploy with UptimeRobot, Better Stack, Cronitor, Healthchecks.io, Plausible, Fathom and Google Analytics: scope, limits, pricing and migration costs.",
        nav_label: "Alternatives",
        summary:
          "Direct comparisons between PostDeploy and uptime, cron and analytics tools, with pricing, limits and migration tradeoffs.",
        hero_heading: "Compare PostDeploy with the tools you use now.",
        hero_description:
          "A production project usually needs an uptime monitor, a cron monitor, an error tracker and an analytics script. Each comparison sets one of those tools against PostDeploy, which covers all four in one project. #{Package.trial_days()} days free, no card, then #{PackagePresenter.price()} a month per organisation.",
        group: "core",
        priority: "0.8",
        lastmod: ~D[2026-09-15],
        body_sections: [
          %{
            "heading" => "What the comparisons are for",
            "body" => [
              "You run one project in production. You need to know when it is down, when a scheduled job fails, which error broke it and how many people visit.",
              "Solo developers often cover that with four tools. Each comparison lists one tool's scope, limits and price next to PostDeploy's, and what moving takes."
            ]
          },
          %{
            "heading" => "Start with the bill you already pay",
            "body" => [
              "Paying for uptime? UptimeRobot and Cronitor count a cron job against the same limit as your monitors, so every scheduled job spends a slot. PostDeploy gives uptime and cron separate allowances: #{entry.uptime_monitors} monitors and #{entry.cron_jobs} jobs.",
              "Paying for analytics? You pay for one answer: who visited. The same PostDeploy package also tells you when the site is down and what errors it throws.",
              "Paying for both? That is the stack PostDeploy replaces. One project, one login, one flat price."
            ]
          },
          %{
            "heading" => "Five questions to ask of any tool",
            "list" => [
              "Scope. Does it cover the scheduled job, the URL that job feeds, the errors that URL throws and the visitors it gets? Or one of the four, with three more subscriptions to follow?",
              "Allowance shape. Does a cron job use an uptime slot? On PostDeploy it does not: #{entry.uptime_monitors} uptime and API monitors plus #{entry.cron_jobs} cron and heartbeat jobs.",
              "Price shape. Flat per organisation, or a meter per monitor, per seat, per heartbeat? A meter turns growth into a bigger invoice.",
              "Alert channels. Email, Slack, Discord, webhooks and Telegram are in PostDeploy, including the #{Package.trial_days()}-day trial.",
              "Seats and projects. PostDeploy has #{entry.projects} projects and #{entry.members} members, with no per-seat fee."
            ]
          },
          %{
            "heading" => "Switching takes one line per job",
            "body" => [
              "Each heartbeat is one URL in a crontab, a CI workflow or application code. Replace the line and the job reports to PostDeploy.",
              "PostDeploy does not import checks from another tool. Give your coding agent the list of URLs and intervals, and it recreates them through MCP. You review the result in the dashboard."
            ]
          }
        ],
        faqs: [
          %{
            "q" => "How fast can I switch?",
            "a" =>
              "Connect your coding agent, ask it to recreate the checks, and swap one URL per scheduled job. The trial needs no card, so you can start today."
          },
          %{
            "q" => "Does PostDeploy replace all four tools?",
            "a" =>
              "It covers uptime checks, cron heartbeats, error tracking and cookieless analytics. It has no logs, tracing, session replay or on-call rotations, so keep a separate tool if you need those."
          },
          %{
            "q" => "What happens after the #{Package.trial_days()} days?",
            "a" =>
              "Subscribe for #{PackagePresenter.price()} a month and keep every check, incident and chart. Without a subscription the organisation becomes read-only, and PostDeploy deletes its data #{Package.inactive_retention_days()} days later."
          }
        ]
      },
      %{
        slug: "guides",
        path: "/guides",
        cluster: "guides",
        intent: :informational,
        primary_query: "PostDeploy guides",
        title: "Guides for monitoring, errors and analytics | PostDeploy",
        meta_description:
          "Practical guides for scheduled jobs, production errors, analytics and website operations.",
        nav_label: "Guides",
        summary:
          "Practical guides for monitoring scheduled jobs, investigating errors and understanding analytics.",
        hero_badge: "Guides",
        hero_heading: "Guides for the software you run",
        hero_description:
          "Find practical steps for scheduled jobs, production errors, analytics and website operations.",
        group: "core",
        priority: "0.8",
        lastmod: ~D[2026-09-30],
        body_sections: [],
        faqs: []
      }
    ]
  end

  # -- Guides (pillar pages) ---------------------------------------------

  defp seed_guides do
    Enum.each(guides(), fn attrs ->
      {:ok, _guide} =
        Content.create_guide(attrs,
          authorize?: false,
          upsert?: true,
          upsert_identity: :unique_slug,
          upsert_fields: :replace_all
        )
    end)
  end

  defp guides do
    entry = Package.get().limits

    [
      %{
        slug: "free-cron-job-monitoring",
        path: "/free-cron-job-monitoring",
        cluster: "cron",
        intent: :transactional,
        primary_query: "free cron job monitoring",
        title: "#{Package.trial_days()}-day free trial for cron job monitoring | PostDeploy",
        meta_description:
          "Monitor cron jobs free for #{Package.trial_days()} days: add one curl line and get an alert the moment a job reports a failure. No credit card, separate from your uptime monitors.",
        nav_label: "Cron monitoring trial",
        summary:
          "How to monitor cron jobs, systemd timers, GitHub Actions and Cloudflare Workers cron triggers with a curl heartbeat, what a heartbeat detects, and what the PostDeploy trial covers.",
        hero_badge: "#{Package.trial_days()}-day free trial, no credit card",
        hero_heading: "Monitor cron jobs free for #{Package.trial_days()} days",
        hero_description:
          "Add one curl line to your cron job and PostDeploy records every start, finish and failure, and alerts you when a run fails. The trial includes #{Package.limit(:cron_jobs)} cron and heartbeat jobs with no credit card, separate from the #{Package.limit(:uptime_monitors)} uptime monitors.",
        related_guide_path: "/free-uptime-monitoring",
        author_name: @author,
        published_on: @lastmod,
        last_verified_on: @lastmod,
        lastmod: ~D[2026-08-31],
        body_sections: [
          %{
            "heading" => "How to monitor a cron job with curl",
            "body" => [
              "Append a curl call to your cron command. Add the job's exit code to the URL, and PostDeploy records a finish when it is 0 and a fail for any other value.",
              "The ; keeps the ping running after a failed job, so a failing backup reports a fail instead of nothing. The -fsS flags keep curl quiet on success and make it report HTTP errors, which matters inside cron, where every byte of output becomes an email.",
              "Your connected coding agent creates the heartbeat monitor and gives you its URL, which holds an hb_ token. Possession of the token is the authentication, so a bare URL works from any crontab without headers or API keys."
            ],
            "code" =>
              "# Report the job's exit code: 0 records a finish, any other value records a fail.\n0 3 * * * /usr/local/bin/backup.sh; curl -fsS https://ingest.postdeploy.dev/h/hb_YOUR_TOKEN/$?"
          },
          %{
            "heading" => "Measuring how long the job took",
            "body" => [
              "Send one ping when the job starts and one when it finishes, and PostDeploy records the duration between them. Both pings go to the same heartbeat URL with a state query parameter added.",
              "A plain ping with no state parameter is recorded as a finish. Duration tracking is useful the day a backup that normally takes four minutes starts taking forty: the job still \"succeeds\", but you can see it slowing down before it fails."
            ],
            "code" =>
              "curl -fsS \"https://ingest.postdeploy.dev/h/hb_YOUR_TOKEN?state=start\"\n/usr/local/bin/backup.sh\ncurl -fsS \"https://ingest.postdeploy.dev/h/hb_YOUR_TOKEN?state=finish\""
          },
          %{
            "heading" => "What a heartbeat records and detects",
            "body" => [
              "A heartbeat records three kinds of ping: start, finish and fail. A fail ping is sent explicitly, or by a non-zero exit code in the URL. PostDeploy also records the duration between a start and a finish.",
              "A fail is detected at once. It records a Down check, opens an incident and notifies your alert channels. An incident resolves after two passing checks in a row.",
              "A run that started and never finished is detected as hung when the next ping arrives, if the monitor has an expected duration.",
              "A run that never starts sends nothing, so PostDeploy cannot report it. After at least one check, a job on an interval schedule with no ping for twice its interval (at least 5 minutes) shows as Late on the Monitor screen. It sends no alert."
            ]
          },
          %{
            "heading" => "Four places to put the ping",
            "body" => [
              "The same heartbeat URL works anywhere that can make an HTTPS request; GET and POST are treated identically.",
              "Crontab: append the curl call after the job, as above.",
              "systemd timer: with Type=oneshot, ExecStartPost runs only after the main command exits successfully. A failed run sends no ping, so it shows as Late only on an interval schedule.",
              "GitHub Actions: keep the token in an Actions secret, and gate the step on the jobs before it.",
              "Cloudflare Workers cron trigger: ping after the work completes, inside ctx.waitUntil so the scheduled handler can return."
            ],
            "code" =>
              "[Service]\nType=oneshot\nExecStart=/usr/local/bin/backup.sh\nExecStartPost=/usr/bin/curl -fsS https://ingest.postdeploy.dev/h/hb_YOUR_TOKEN"
          },
          %{
            "heading" => "Heartbeat monitoring vs uptime checks",
            "body" => [
              "A heartbeat is your job telling PostDeploy it ran; an uptime check is PostDeploy asking your URL whether it is alive. Heartbeats fit anything scheduled or headless, like cron jobs, queue workers and CI pipelines, while uptime checks fit anything with an endpoint, like an API, a site or a webhook receiver.",
              "Most real projects need a few of each, so cron and heartbeat jobs have their own allowance, separate from uptime monitors, in PostDeploy. Monitoring a scheduled job never uses an uptime monitor."
            ]
          },
          %{
            "heading" => "What the package covers",
            "body" => [
              "Uptime checks, cron heartbeats, error tracking and cookieless analytics are all in the same package. The #{Package.trial_days()}-day trial includes #{entry.cron_jobs} cron jobs, #{entry.uptime_monitors} uptime monitors, #{div(entry.min_check_interval_seconds, 60)}-minute intervals and #{entry.detailed_uptime_retention_days} days of detailed uptime samples. After the trial, the same limits cost #{PackagePresenter.price()} a month."
            ],
            "list" => [
              "#{Package.limit(:cron_jobs)} cron and heartbeat jobs on the trial, separate from #{Package.limit(:uptime_monitors)} uptime monitors",
              "1-minute minimum check interval on the trial",
              "#{Package.limit(:detailed_uptime_retention_days)} days of detailed uptime samples on the trial",
              "Email, Slack, Discord, webhook and Telegram alerts included",
              "No credit card for the #{Package.trial_days()} days"
            ]
          }
        ],
        faqs: [
          %{
            "q" => "Do I need to install software on my server to monitor cron jobs?",
            "a" =>
              "No. The job itself makes one outbound HTTPS request, so anything that can run curl, wget or fetch can ping a heartbeat. Your coding agent creates the heartbeat monitor over MCP."
          },
          %{
            "q" => "Does the heartbeat URL need authentication?",
            "a" =>
              "No separate header or key: possession of the hb_ token in the URL is the authentication. Treat the URL like a secret and keep it in your crontab or CI secret store, not in a public repo."
          },
          %{
            "q" => "Can I ping with wget or a plain HTTP library instead of curl?",
            "a" =>
              "Yes. GET and POST are accepted and treated identically, so wget, a fetch() call or any HTTP client works exactly the same as curl."
          },
          %{
            "q" => "Is cron job monitoring included in the trial?",
            "a" =>
              "Yes. The trial includes #{Package.limit(:cron_jobs)} cron and heartbeat jobs, separate from its #{Package.limit(:uptime_monitors)} uptime monitors, with 1-minute minimum intervals, no credit card required. The same #{entry.cron_jobs} cron jobs stay after the trial, for #{PackagePresenter.price()} a month."
          }
        ]
      },
      %{
        slug: "free-uptime-monitoring",
        path: "/free-uptime-monitoring",
        cluster: "uptime",
        intent: :transactional,
        primary_query: "free uptime monitoring",
        title: "#{Package.trial_days()}-day free trial for uptime monitoring | PostDeploy",
        meta_description:
          "#{Package.limit(:uptime_monitors)} uptime and API monitors, #{Package.limit(:cron_jobs)} cron jobs and 1-minute checks free for #{Package.trial_days()} days, no credit card. Built for one production side project.",
        nav_label: "Uptime monitoring trial",
        summary:
          "What the PostDeploy trial covers for uptime monitoring, how the checks run, and how it compares with other monitoring tools' entry plans.",
        hero_badge: "#{Package.trial_days()}-day free trial, no credit card",
        hero_heading: "Monitor uptime free for #{Package.trial_days()} days",
        hero_description:
          "PostDeploy gives you #{Package.limit(:uptime_monitors)} uptime monitors, #{Package.limit(:cron_jobs)} cron jobs and 1-minute checks free for #{Package.trial_days()} days with no credit card. Sign up at the bottom of this page.",
        related_guide_path: "/free-cron-job-monitoring",
        author_name: @author,
        published_on: @lastmod,
        last_verified_on: @lastmod,
        lastmod: ~D[2026-08-31],
        body_sections: [
          %{
            "heading" => "What the free trial covers",
            "body" => [
              "The #{Package.trial_days()}-day trial includes #{Package.limit(:uptime_monitors)} uptime monitors, #{Package.limit(:cron_jobs)} cron jobs, checks every minute, and alerts by email, Slack, Discord, webhook and Telegram. It needs no credit card.",
              "Uptime checks and cron-job heartbeats have separate allowances: #{Package.limit(:uptime_monitors)} uptime monitors for HTTP checks and #{Package.limit(:cron_jobs)} cron jobs for heartbeats. That is room for a real project with customers: the API, the site, the marketing page, and the scheduled jobs behind them. After the trial, the same limits cost #{PackagePresenter.price()} a month."
            ]
          },
          %{
            "heading" => "How the checks run",
            "body" => [
              "Checks run from one location, the PostDeploy application servers. Each check requests your URL, and a failed or timed-out response opens an incident and sends the alert to the channels you configured. A failure is not confirmed from a second location, so a network problem between that location and your server can read as downtime.",
              "The check interval floor is #{div(Package.limit(:min_check_interval_seconds), 60)} minute, on the trial and after it. There is no faster tier to buy."
            ]
          },
          %{
            "heading" => "How this compares to other free tiers",
            # UptimeRobot free tier: 50 monitors, 3 months retention, 5-minute
            # interval; heartbeats and Slack gated to paid plans
            # (https://uptimerobot.com/pricing/, checked 2026-08-03).
            "body" => [
              "Dedicated uptime tools publish bigger free monitor allowances than most entry plans. What those tiers leave out: cron heartbeats with their own allowance, Slack alerts on free, and error tracking and analytics under the same login.",
              "The PostDeploy trial covers one real project end to end: #{Package.limit(:uptime_monitors)} uptime monitors, #{Package.limit(:cron_jobs)} cron jobs, and the other two pillars live in the same package.",
              "If uptime is one of three things you would otherwise wire up separately, one toolkit beats three subscriptions."
            ]
          },
          %{
            "heading" => "Also running cron jobs?",
            "body" => [
              "Uptime checks request a URL, so they cannot see a scheduled job that has no URL. Heartbeats cover that side: the job pings PostDeploy when it starts, finishes or fails, and a fail opens an incident at once. Cron jobs have their own allowance of #{Package.limit(:cron_jobs)} on the trial. The one-curl setup is in the cron monitoring trial guide."
            ]
          }
        ],
        faqs: [
          %{
            "q" => "What happens after the #{Package.trial_days()} days?",
            "a" =>
              "Without a subscription the organisation becomes read-only: every chart and incident stays visible, but writes and ingest stop. Data is kept #{Package.inactive_retention_days()} more days, then purged. Subscribing for #{PackagePresenter.price()} a month keeps everything configured."
          },
          %{
            "q" => "What counts as a monitor?",
            "a" =>
              "One HTTP uptime check uses one of the uptime monitors. One cron-job heartbeat uses one of the cron jobs; the allowances are separate."
          },
          %{
            "q" => "How fast will I know my site is down?",
            "a" =>
              "Checks run every minute, during the trial and after it, so in the worst case a failure is detected about a minute after it starts."
          },
          %{
            "q" => "Can I get alerts in Slack or Discord?",
            "a" =>
              "Yes, in the subscription and during the trial, alongside email. Webhook and Telegram channels are included too."
          }
        ]
      }
    ]
  end

  # -- Comparisons --------------------------------------------------------

  defp seed_comparisons do
    Enum.each(comparisons(), fn attrs ->
      {:ok, _comparison} =
        Content.create_comparison(attrs,
          authorize?: false,
          upsert?: true,
          upsert_identity: :unique_slug,
          upsert_fields: :replace_all
        )
    end)
  end

  # Competitor figures policy: every figure below comes from a page the
  # vendor owns. Each comparison exposes those source URLs and the date
  # they were checked.
  # PostDeploy's own numbers are interpolated from `Alplus.Billing.Package` where a
  # row states them.
  defp comparisons do
    package = Package.get()
    entry = package.limits

    price = PackagePresenter.price()

    monthly_price = "#{price} a month"

    [
      # Sources rendered below, all checked 2026-08-03:
      # - https://cronitor.io/pricing — plan tiers, monitor counts, interval
      #   floors, status page and seat pricing ($2/monitor, $5/user,
      #   Enterprise from $6,000/year).
      # - https://cronitor.io/docs/cron-job-monitoring — job state machine,
      #   tolerances, duration assertions, platform integrations.
      # - https://cronitor.io/docs/uptime-monitoring — check regions, static
      #   IPs, assertions, SSL expiry warnings.
      # - https://cronitor.io/docs/rum-faq — analytics billing model.
      %{
        slug: "cronitor",
        path: "/alternatives/cronitor",
        cluster: "comparison",
        intent: :commercial_investigation,
        primary_query: "cronitor alternative",
        title: "Cronitor alternative for cron and uptime monitoring | PostDeploy",
        meta_description:
          "PostDeploy against Cronitor: separate uptime and cron allowances, a flat price instead of a per-monitor meter, plus errors and analytics.",
        nav_label: "Cronitor alternative",
        summary:
          "PostDeploy against Cronitor: entry allowances line by line, a flat price against a per-monitor meter, and a move that takes one line per job.",
        lastmod: ~D[2026-08-31],
        competitor_name: "Cronitor",
        competitor_homepage: "https://cronitor.io/",
        positioning:
          "Cronitor sells a developer monitoring suite covering cron jobs, uptime checks, heartbeats, status pages and cookie-free analytics, to teams that want backend jobs and frontend health in one tool.",
        tldr:
          "PostDeploy is #{monthly_price} for #{entry.uptime_monitors} uptime monitors and #{entry.cron_jobs} cron jobs on separate allowances, with error tracking and analytics on the same login. Cronitor gives you five shared monitors free, then bills $2 per monitor and $5 per user until Enterprise at $6,000 a year. Stop feeding a meter. Move your jobs to PostDeploy.",
        body_sections: [
          %{
            "heading" => "Pricing, tier by tier",
            "body" => [
              # fact: Cronitor pricing (entry why_looking, free_tier_rows)
              "Free is five monitors, shared across uptime checks, heartbeats and cron jobs, at a 5-minute floor. A branded status page costs $25 a month. A private one costs $50.",
              # fact: Cronitor pricing (entry why_looking, faqs)
              "Past free there is no plan, only a meter: $2 per monitor per month plus $5 per dashboard user. Fifteen monitors and one seat is $35 a month. The line climbs with every object until Enterprise, which starts at $6,000 a year.",
              "PostDeploy is #{monthly_price}, flat per organisation: #{entry.projects} projects, #{entry.uptime_monitors} uptime monitors and #{entry.cron_jobs} cron jobs on separate allowances, so a scheduled job never spends the slot for the URL it serves."
            ]
          },
          %{
            "heading" => "One metered pool, or a flat price",
            "body" => [
              "On Cronitor a cron job and the URL it serves draw from the same metered pool. Add a job and pay $2. Add a teammate who needs to see it and pay $5.",
              "PostDeploy counts jobs and monitors apart and charges once. Each job reports start, finish or fail with one curl line and no SDK, or sends its exit code in the URL. A fail ping or a non-zero exit opens an incident at once. The same package polls #{entry.uptime_monitors} HTTP, keyword, TCP and DNS checks, groups errors with releases and sourcemaps, and counts pageviews without cookies."
            ]
          },
          %{
            "heading" => "The line that changes",
            "body" => [
              "Keep the command and swap the URL. The exit code goes in the path, so a failed run reports a fail instead of nothing."
            ],
            "code" =>
              "# Before: Cronitor\n./backup.sh; curl -fsS \"https://cronitor.link/p/API_KEY/backup?state=complete\"\n\n# After: PostDeploy\n./backup.sh; curl -fsS https://ingest.postdeploy.dev/h/hb_YOUR_TOKEN/$?",
            "filename" => "job.sh",
            "language" => "shell"
          }
        ],
        why_looking: [
          "The free tier stops at five monitors. One API and four cron jobs fill it.",
          "Past the free tier there is no next plan, only a meter. The bill climbs with every monitor and every person who opens the dashboard.",
          "Status pages are unbundled. Branding one or locking it is a separate monthly charge."
        ],
        free_tier_rows: [
          %{
            "label" => "Uptime and API monitors",
            "them" => "5 shared with jobs",
            "us" => "#{entry.uptime_monitors}, own allowance",
            "edge" => "us"
          },
          %{
            "label" => "Cron and heartbeat jobs",
            "them" => "Shared with the 5 above",
            "us" => "#{entry.cron_jobs}, own allowance",
            "edge" => "us"
          },
          %{
            "label" => "Check interval floor",
            "them" => "5 minutes",
            "us" => "#{PackagePresenter.interval_label(entry.min_check_interval_seconds)}",
            "edge" => "us"
          },
          %{
            "label" => "Failed job alerts",
            "them" => "Failure, missed-run and duration alerts",
            "us" => "A fail ping or non-zero exit alerts at once",
            "edge" => "mixed"
          },
          %{
            "label" => "Seats on the entry plan",
            "them" => "1",
            "us" => "#{entry.members}",
            "edge" => "even"
          },
          %{
            "label" => "Pricing model past free",
            "them" => "Metered: $2 / monitor, $5 / user",
            "us" => "One package, #{monthly_price}",
            "edge" => "us"
          },
          %{
            "label" => "Analytics and error tracking",
            "them" => "Shipped today (RUM, JS errors)",
            "us" => "Shipped today (Measure, Observe)",
            "edge" => "even"
          }
        ],
        they_do_better: [],
        we_do_better: [
          "Separate allowances, not one pool. PostDeploy counts #{entry.uptime_monitors} uptime and API monitors and #{entry.cron_jobs} cron and heartbeat jobs apart, so watching a scheduled job never uses up the allowance for the URL it serves. Cronitor bills every object from one metered pool.",
          "A flat price, not a meter. PostDeploy is #{monthly_price} for #{package.limits.projects} projects, #{package.limits.uptime_monitors} uptime monitors and #{package.limits.cron_jobs} cron jobs. At Cronitor's $2 per monitor, the same #{package.limits.uptime_monitors + package.limits.cron_jobs} objects cost $#{(package.limits.uptime_monitors + package.limits.cron_jobs) * 2} a month before seats.",
          "Analytics and error tracking in the same package and the same projects, not as separately metered products.",
          "Projects and environments across every signal, including uptime checks. Cronitor's environments apply to job telemetry, and its uptime checks all run in the account's default environment.",
          "Room for client work: #{entry.projects} projects and #{entry.members} members in one package, so each client's monitors and jobs stay in their own project."
        ],
        stay_with_them: [],
        switch_to_us: [
          "You are out of free monitors and you refuse to pay per object.",
          "You want next month's bill to match this month's.",
          "You want a failed run to open an incident the moment the job reports it.",
          "You want uptime, heartbeats, errors and analytics on one login today."
        ],
        migration: [
          "Swap each ping URL. Cronitor telemetry endpoints look like `https://cronitor.link/p/API_KEY/<key>?state=run|complete|fail` and live in crontabs, Kubernetes manifests, GitHub Actions workflows and application code. PostDeploy takes the same shape: `?state=start|finish|fail`, or the exit code in the path.",
          "If CronitorCLI rewrote your crontab, strip its wrappers before you swap the URLs.",
          "Remove the `cronitor` SDK packages (Python, Node, Ruby, PHP). A PostDeploy heartbeat is one curl line.",
          "Let your agent recreate each uptime check through MCP: URL, interval, timeout, expected status and keyword rule.",
          "Check that each job reports its own failure. A fail ping or a non-zero exit alerts at once, and a job that sends nothing sends no alert.",
          "Point alerts at email, Slack, Discord, a webhook or Telegram."
        ],
        unverified: [],
        faqs: [
          %{
            "q" => "What does a PostDeploy heartbeat report?",
            "a" =>
              "Start, finish and fail, sent with one curl line and no SDK, or the job's exit code in the URL. A fail ping or a non-zero exit code opens an incident at once. Uptime checks, error tracking and analytics come in the same package."
          },
          %{
            "q" => "Does PostDeploy alert when a job never runs?",
            "a" =>
              "A fail ping or a non-zero exit code alerts at once. A job that sends nothing sends no alert, and an interval job shows as Late on the Monitor screen. Cronitor alerts on missed runs and on duration limits you set."
          },
          %{
            "q" => "How many monitors does Cronitor's free plan include?",
            "a" =>
              "Five, shared across cron jobs, heartbeats and uptime checks, at a 5-minute check interval floor. PostDeploy counts the two apart: #{entry.uptime_monitors} uptime and API monitors and #{entry.cron_jobs} cron and heartbeat jobs, with uptime checks as often as every #{PackagePresenter.interval_label(entry.min_check_interval_seconds)}."
          },
          %{
            "q" => "What does Cronitor cost once you outgrow the free plan?",
            "a" =>
              "There is no flat next tier. Business is metered at $2 per monitor per month plus $5 per dashboard user, so the bill grows with every object you add. Enterprise starts at $6,000 a year. PostDeploy is a flat #{monthly_price}."
          },
          %{
            "q" => "How do I start?",
            "a" =>
              "Sign up. You get #{Package.trial_days()} days free, with no credit card and no invite."
          }
        ],
        sources: [
          %{
            "label" => "Cronitor pricing",
            "url" => "https://cronitor.io/pricing",
            "retrieved" => "2026-08-03"
          },
          %{
            "label" => "Cron job monitoring documentation",
            "url" => "https://cronitor.io/docs/cron-job-monitoring",
            "retrieved" => "2026-10-12"
          },
          %{
            "label" => "Uptime monitoring documentation",
            "url" => "https://cronitor.io/docs/uptime-monitoring",
            "retrieved" => "2026-08-03"
          },
          %{
            "label" => "Real user monitoring FAQ",
            "url" => "https://cronitor.io/docs/rum-faq",
            "retrieved" => "2026-08-03"
          }
        ]
      },
      # Sources rendered below, all checked 2026-08-03:
      # - https://uptimerobot.com/pricing/ — plan structure, free-tier
      #   limits, integration gating (50 free monitors, Slack paid,
      #   webhooks third tier).
      # - https://help.uptimerobot.com/en/articles/11360873-... — retention
      #   by plan (3, 12, 24 months).
      # - https://help.uptimerobot.com/en/articles/11604710-... — free plan
      #   scope and commercial-use policy.
      # - https://help.uptimerobot.com/en/articles/16160088-... — downgrade
      #   pauses all monitors; SSL reminders not restored.
      # - https://uptimerobot.com/cron-job-monitoring/ — heartbeat URL
      #   format. Their pricing page gates heartbeats to paid plans; a
      #   help-centre article contradicts it, so copy avoids the claim.
      %{
        slug: "uptimerobot",
        path: "/alternatives/uptimerobot",
        cluster: "comparison",
        intent: :commercial_investigation,
        primary_query: "uptimerobot alternative",
        title: "UptimeRobot alternative: cron, errors, analytics | PostDeploy",
        meta_description:
          "PostDeploy against UptimeRobot: Slack and webhook alerts in every subscription, cron jobs on their own allowance, plus errors and analytics.",
        nav_label: "UptimeRobot alternative",
        summary:
          "PostDeploy against UptimeRobot: the alert channels UptimeRobot charges for, cron jobs on their own allowance, and errors and analytics in one package.",
        lastmod: ~D[2026-08-31],
        competitor_name: "UptimeRobot",
        competitor_homepage: "https://uptimerobot.com/",
        positioning:
          "UptimeRobot sells external synthetic monitoring (HTTP, keyword, ping, port, DNS and heartbeat checks) plus hosted status pages, to everyone from hobbyists on its free plan up to enterprise teams.",
        tldr:
          "PostDeploy puts Slack, Discord, webhook and Telegram alerts in every subscription, gives cron jobs their own allowance, and adds error tracking and analytics to the same projects. UptimeRobot keeps Slack and webhooks off its free plan and tracks no errors and no visitors. Get the alerts without a plan ladder. Switch to PostDeploy.",
        body_sections: [
          %{
            "heading" => "Pricing, tier by tier",
            "body" => [
              # fact: UptimeRobot pricing page (entry free_tier_rows, why_looking)
              "Free is 50 monitors at a 5-minute floor, with Discord alerts. Slack is not on it.",
              # fact: UptimeRobot pricing page (entry sources, why_looking)
              "Read the integration column, not the monitor count. Slack starts at the entry paid tier. Webhooks start two tiers above that. A team that wants Slack alerts and one webhook into an internal handler buys the higher tier long before it needs a 51st monitor.",
              "PostDeploy is #{monthly_price}, flat, with email, Slack, Discord, webhook and Telegram in every subscription: #{entry.projects} projects, #{entry.uptime_monitors} uptime monitors, and #{entry.cron_jobs} cron and heartbeat jobs on their own allowance."
            ]
          },
          %{
            "heading" => "The alert paywall and the missing pillars",
            "body" => [
              "A free monitor stops being free the moment a second person needs the alert in Slack. PostDeploy routes email, Slack, Discord, webhook and Telegram.",
              "Most projects are an API, a marketing site, a staging host, four scheduled jobs and a question about last week's traffic. PostDeploy gives the jobs their own allowance, #{entry.cron_jobs} in the package, and puts the errors and the traffic in the same project. UptimeRobot sells neither error tracking nor analytics."
            ]
          },
          %{
            "heading" => "The line that changes",
            "body" => [
              "Keep the command and swap the URL. The exit code goes in the path, so a failed run reports a fail instead of nothing."
            ],
            "code" =>
              "# Before: UptimeRobot\n./backup.sh && curl -fsS https://heartbeat.uptimerobot.com/YOUR_ID\n\n# After: PostDeploy\n./backup.sh; curl -fsS https://ingest.postdeploy.dev/h/hb_YOUR_TOKEN/$?",
            "filename" => "job.sh",
            "language" => "shell"
          }
        ],
        why_looking: [
          "In November 2024 UptimeRobot retroactively restricted its free plan to non-commercial use, told users after the change had taken effect, and set a deadline under a month out. It reversed the policy later, but the terms changed once without warning.",
          "Slack is not on the free plan, and webhooks are not on the free or entry plan. For a small team that turns a free monitor into a paid one.",
          "Downgrading pauses every monitor, not just the ones over the new limit, and it silently turns off SSL and domain expiry reminders that re-upgrading does not restore."
        ],
        free_tier_rows: [
          %{
            "label" => "Cron and heartbeat jobs",
            "them" => "Shared with the 50 monitors",
            "us" => "#{entry.cron_jobs}, own allowance",
            "edge" => "us"
          },
          %{
            "label" => "Check interval floor",
            "them" => "5 minutes",
            "us" => "#{PackagePresenter.interval_label(entry.min_check_interval_seconds)}",
            "edge" => "us"
          },
          %{
            "label" => "Slack alerts",
            "them" => "Paid plans only",
            "us" => "Included",
            "edge" => "us"
          },
          %{
            "label" => "Webhook alerts",
            "them" => "Third tier up",
            "us" => "One package, #{monthly_price}",
            "edge" => "us"
          },
          %{
            "label" => "Discord alerts",
            "them" => "Free plan",
            "us" => "Included",
            "edge" => "even"
          },
          %{
            "label" => "Error tracking and analytics",
            "them" => "Not offered",
            "us" => "Included",
            "edge" => "us"
          }
        ],
        they_do_better: [],
        we_do_better: [
          "One project, four signals. Uptime monitors, cron and heartbeat jobs, error tracking and analytics share the same projects, one login and one bill.",
          "Cron and heartbeat jobs have their own allowance, #{entry.cron_jobs} in the package, so watching a scheduled job never spends an uptime monitor or costs extra.",
          "Slack is included in PostDeploy. On UptimeRobot it starts at the entry paid tier, and webhooks start two tiers above that.",
          "Projects and environments, so staging and production are separate views of the same project, not two unrelated monitors.",
          "A flat, published price: PostDeploy is #{monthly_price} for the whole project."
        ],
        stay_with_them: [],
        switch_to_us: [
          "You refuse to pay for Slack alerts.",
          "Your project is an API, a site, a marketing page and a handful of scheduled jobs, inside #{entry.uptime_monitors} uptime monitors and #{entry.cron_jobs} cron jobs.",
          "You run staging and production and want them modelled that way.",
          "You want uptime, errors and analytics in one tool today, not three."
        ],
        migration: [
          "Read your monitors out through the UptimeRobot REST API: type, URL, interval, timeout, keyword rules and accepted status codes.",
          "Let your agent recreate each check in PostDeploy through MCP.",
          "Swap each heartbeat URL. A unique `heartbeat.uptimerobot.com/<id>` sits in each crontab, CI pipeline, Task Scheduler action or piece of application code. Replace it with the PostDeploy URL.",
          "Check that each job reports its own failure. A fail ping or a non-zero exit alerts at once, and a job that sends nothing sends no alert.",
          "Point alerts at email, Slack, Discord, a webhook or Telegram."
        ],
        unverified: [],
        faqs: [
          %{
            "q" => "How does PostDeploy compare with UptimeRobot's free plan?",
            "a" =>
              "UptimeRobot's free plan leaves out Slack and webhooks. PostDeploy has Slack, Discord, webhook and Telegram alerts, #{entry.uptime_monitors} uptime monitors, #{entry.cron_jobs} cron and heartbeat jobs on a separate allowance, and error tracking and analytics, for #{monthly_price}."
          },
          %{
            "q" => "Can I monitor a cron job on PostDeploy?",
            "a" =>
              "Yes. Cron and heartbeat jobs have their own allowance of #{entry.cron_jobs} in the package, separate from uptime monitors, so a scheduled job never consumes an uptime slot. A fail ping or a non-zero exit code opens an incident at once."
          },
          %{
            "q" => "Does PostDeploy do port and DNS checks?",
            "a" =>
              "Yes. PostDeploy runs HTTP, keyword, TCP port and DNS checks, plus heartbeats and SSL and domain expiry warnings."
          }
        ],
        sources: [
          %{
            "label" => "UptimeRobot pricing",
            "url" => "https://uptimerobot.com/pricing/",
            "retrieved" => "2026-08-03"
          },
          %{
            "label" => "Cron job monitoring",
            "url" => "https://uptimerobot.com/cron-job-monitoring/",
            "retrieved" => "2026-08-03"
          }
        ]
      },
      # Sources rendered below, all checked 2026-08-03:
      # - https://healthchecks.io/pricing/ — plan names, prices, check
      #   counts, ping-log limits (20 free checks, $20/month for 100).
      # - https://healthchecks.io/docs/ — deliberately no HTTP uptime
      #   probing.
      # - https://healthchecks.io/docs/projects_teams/ — no seat limits,
      #   four roles.
      # - https://healthchecks.io/docs/self_hosted/ — self-hosting
      #   requirements.
      # - https://github.com/healthchecks/healthchecks/blob/master/LICENSE
      #   — BSD 3-Clause.
      %{
        slug: "healthchecks-io",
        path: "/alternatives/healthchecks-io",
        cluster: "comparison",
        intent: :commercial_investigation,
        primary_query: "healthchecks.io alternative",
        title: "Healthchecks.io alternative with uptime checks | PostDeploy",
        meta_description:
          "PostDeploy against Healthchecks.io: cron heartbeats plus the HTTP uptime checks Healthchecks.io does not run, with errors and analytics in one package.",
        nav_label: "Healthchecks.io alternative",
        summary:
          "PostDeploy against Healthchecks.io: heartbeats plus uptime checks, errors and analytics, against a tool that watches heartbeats only.",
        lastmod: ~D[2026-08-31],
        competitor_name: "Healthchecks.io",
        competitor_homepage: "https://healthchecks.io/",
        positioning:
          "Healthchecks.io sells heartbeat monitoring for cron jobs, backups and scheduled tasks: you ping a URL on success and it alerts you when the ping does not arrive. It is BSD-licensed and self-hostable.",
        tldr:
          "PostDeploy takes your job's start, finish and fail pings and checks the URL it serves, in one project: #{entry.cron_jobs} cron jobs plus #{entry.uptime_monitors} uptime monitors in the package, with error tracking and analytics on the same login. Healthchecks.io probes no URLs on any tier, so your site needs a second tool and a second bill. Drop the second tool. Run both on PostDeploy.",
        body_sections: [
          %{
            "heading" => "Pricing, tier by tier",
            "body" => [
              # fact: Healthchecks.io pricing page (entry free_tier_rows, migration)
              "Free is 20 checks, and the ping log keeps 100 entries per check. The next tier is $20 a month for 100 checks.",
              # fact: Healthchecks.io documentation (entry why_looking, faqs)
              "Every step on that ladder buys more heartbeats. None of it buys a check on the URL those jobs feed. The site needs a second subscription, a second login and a second alert policy, so the $20 tier is only part of the bill.",
              "PostDeploy is #{monthly_price}, flat, and counts both: #{entry.cron_jobs} cron and heartbeat jobs plus #{entry.uptime_monitors} uptime and API monitors across #{entry.projects} projects, with error tracking and cookieless analytics in the same package. Twenty jobs and a dozen URLs is one bill."
            ]
          },
          %{
            "heading" => "The job and the URL it serves, in one place",
            "body" => [
              "A job rarely fails alone. The importer that stopped is why the dashboard is empty. The endpoint that returns 502 is why the webhook never fired. Split across two vendors, you match two timelines by hand in the middle of the incident.",
              "PostDeploy keeps both in one project: #{entry.uptime_monitors} polled HTTP, keyword, TCP and DNS checks and #{entry.cron_jobs} heartbeat jobs under one alert policy. A job that pings fail or exits non-zero opens an incident at once, next to the uptime history of the URL it serves."
            ]
          },
          %{
            "heading" => "The line that changes",
            "body" => [
              "Keep the command and swap the URL. Both services take the exit code in the path."
            ],
            "code" =>
              "# Before: Healthchecks.io\n./backup.sh; curl -fsS https://hc-ping.com/YOUR_UUID/$?\n\n# After: PostDeploy\n./backup.sh; curl -fsS https://ingest.postdeploy.dev/h/hb_YOUR_TOKEN/$?",
            "filename" => "job.sh",
            "language" => "shell"
          }
        ],
        why_looking: [
          "You added a website to monitor and found nowhere to put it. Healthchecks.io does not probe URLs; its docs list uptime monitoring under what it is not for.",
          "You already run two tools, one for jobs and one for uptime, and you watch both.",
          "Errors and visitor numbers live in a third and fourth tool, each with its own login."
        ],
        free_tier_rows: [
          %{
            "label" => "Cron and heartbeat jobs",
            "them" => "20 checks",
            "us" => "#{entry.cron_jobs}, own allowance",
            "edge" => "us"
          },
          %{
            "label" => "Failed job alerts",
            "them" =>
              "Fail and exit-code pings alert, as does a ping that does not arrive on time",
            "us" => "A fail ping or non-zero exit alerts at once",
            "edge" => "mixed"
          },
          %{
            "label" => "HTTP uptime checks",
            "them" => "Not offered",
            "us" => "Own allowance, #{entry.uptime_monitors} in the package",
            "edge" => "us"
          },
          %{
            "label" => "Error tracking and analytics",
            "them" => "Not offered",
            "us" => "Included",
            "edge" => "us"
          },
          %{
            "label" => "Next tier up",
            "them" => "$20 / month for 100 checks",
            "us" => "#{monthly_price}, flat",
            "edge" => "mixed"
          }
        ],
        they_do_better: [],
        we_do_better: [
          "Uptime checks on their own allowance. PostDeploy has #{entry.uptime_monitors} uptime and API monitors alongside #{entry.cron_jobs} cron and heartbeat jobs, so one tool covers the scheduled job and the URL it keeps alive.",
          "Failed runs surface at once. A fail ping or a non-zero exit code opens an incident beside the uptime history of the URL the job serves.",
          "Projects and environments across every signal, with errors and analytics on the same login.",
          "One flat-priced package for the whole project, so adding an uptime monitor or an error feed never means adding a vendor."
        ],
        stay_with_them: [],
        switch_to_us: [
          "You pay for an uptime monitor somewhere else, or you are about to.",
          "You want the job and the endpoint it feeds in one project with one alert policy.",
          "You want errors and visitor numbers for the same project under the same login.",
          "You want your jobs and your site checked by one tool instead of two."
        ],
        migration: [
          "Export your checks through the Management API (`GET /api/v3/checks/`) to get names, tags and schedules in one pass.",
          "Swap every ping URL. `hc-ping.com/<uuid>` sits in crontabs, systemd units, backup scripts, Dockerfile healthchecks, CI workflows and Kubernetes CronJobs. Keep the command and replace the URL.",
          "Report state the PostDeploy way: `?state=start|finish|fail`, or the exit code in the path.",
          "Let your agent add uptime checks for the URLs those jobs feed, through MCP.",
          "Check that each job reports its own failure. A fail ping or a non-zero exit alerts at once, and a job that sends nothing sends no alert.",
          "Connect Slack, Discord, Telegram, a webhook or email in PostDeploy."
        ],
        unverified: [],
        faqs: [
          %{
            "q" => "Does Healthchecks.io do uptime monitoring?",
            "a" =>
              "No. Its documentation lists probing a website with HTTP requests under what the tool is not for. It is heartbeats only, on every tier, hosted or self-hosted. On PostDeploy uptime checks have their own allowance, #{entry.uptime_monitors} in the package."
          },
          %{
            "q" => "What does a PostDeploy heartbeat report?",
            "a" =>
              "Start, finish and fail, or the job's exit code in the URL. A fail ping or a non-zero exit code opens an incident at once. Uptime checks, error tracking and analytics come in the same package."
          },
          %{
            "q" => "Does PostDeploy alert when a job never runs?",
            "a" =>
              "A fail ping or a non-zero exit code alerts at once. A job that sends nothing sends no alert, and an interval job shows as Late on the Monitor screen. Healthchecks.io alerts when an expected ping does not arrive within its grace time."
          },
          %{
            "q" => "Can I keep my existing crontab entries?",
            "a" =>
              "Yes. The command stays the same; only the ping URL changes. Each `hc-ping.com` URL becomes a PostDeploy heartbeat URL, pinged the same way with curl or wget."
          }
        ],
        sources: [
          %{
            "label" => "Healthchecks.io pricing",
            "url" => "https://healthchecks.io/pricing/",
            "retrieved" => "2026-08-03"
          },
          %{
            "label" => "Healthchecks.io documentation",
            "url" => "https://healthchecks.io/docs/",
            "retrieved" => "2026-10-12"
          },
          %{
            "label" => "Projects and teams documentation",
            "url" => "https://healthchecks.io/docs/projects_teams/",
            "retrieved" => "2026-08-03"
          },
          %{
            "label" => "Self-hosting documentation",
            "url" => "https://healthchecks.io/docs/self_hosted/",
            "retrieved" => "2026-08-03"
          },
          %{
            "label" => "BSD 3-Clause license",
            "url" => "https://github.com/healthchecks/healthchecks/blob/master/LICENSE",
            "retrieved" => "2026-08-03"
          }
        ]
      },
      # Sources rendered below, all checked 2026-08-03:
      # - https://betterstack.com/pricing — seat, monitor, heartbeat,
      #   status page and telemetry prices; free-tier allowances
      #   ($34/responder, $25/50 monitors, $20/10 heartbeats, $250
      #   unbranded page, $50 password protection).
      # - https://betterstack.com/uptime — free tier marketed as 10
      #   monitors, 10 heartbeats, 3-minute checks.
      # - https://betterstack.com/docs/uptime/check-frequency/ — 3 minutes
      #   free, 30 seconds paid.
      # - https://betterstack.com/docs/uptime/cron-and-heartbeat-monitor/
      #   — heartbeat mechanics.
      # - https://betterstack.com/docs/uptime/team-management/manage-roles/
      #   — free members cannot access monitors.
      %{
        slug: "better-stack",
        path: "/alternatives/better-stack",
        cluster: "comparison",
        intent: :commercial_investigation,
        primary_query: "better stack alternative",
        title: "Better Stack alternative with flat pricing | PostDeploy",
        meta_description:
          "PostDeploy against Better Stack: one flat-priced package for uptime, cron, errors and analytics, not a bill metered per seat, monitor and heartbeat.",
        nav_label: "Better Stack alternative",
        summary:
          "PostDeploy against Better Stack: a flat monthly price against metered seats, monitors and heartbeats, priced at PostDeploy's limits.",
        lastmod: ~D[2026-08-31],
        competitor_name: "Better Stack",
        competitor_homepage: "https://betterstack.com/",
        positioning:
          "Better Stack sells monitoring and incident response in one product: uptime and heartbeat checks, on-call scheduling, status pages, logs, metrics, traces, error tracking and session replay, to teams collapsing a PagerDuty plus Datadog plus Statuspage stack into one vendor.",
        tldr:
          "PostDeploy is #{PackagePresenter.price()} a month, flat, for #{Package.limit(:members)} members, #{Package.limit(:uptime_monitors)} uptime monitors, #{Package.limit(:cron_jobs)} cron jobs, error tracking and analytics. Better Stack charges $34 a month per responder seat, so two people cost $68 before the first extra monitor or heartbeat block. Stop paying per head. Switch to PostDeploy.",
        body_sections: [
          %{
            "heading" => "Pricing, tier by tier",
            "body" => [
              # fact: Better Stack pricing and Better Uptime pages (entry free_tier_rows, why_looking)
              "Free is 10 monitors, 10 heartbeats, 3-minute checks. Above it there is no plan, only a basket: $34 a month per responder seat, $25 per additional 50 monitors, $20 per additional 10 heartbeats, $15 per extra status page, plus per-GB telemetry. Unbranding one status page is $250 a month.",
              # fact: Better Stack pricing and team roles documentation (entry why_looking)
              "Price two people. Free members cannot see monitors, incidents or status pages, so both need a responder licence: 2 x $34 is $68 a month. Ten more heartbeats add $20, and the team sits at $88.",
              "PostDeploy charges once, per organisation. PostDeploy is #{monthly_price}: #{entry.projects} projects, #{entry.members} members, #{entry.uptime_monitors} uptime monitors and #{entry.cron_jobs} cron jobs."
            ]
          },
          %{
            "heading" => "Metering taxes every person who looks",
            "body" => [
              "For a small team the seat model taxes visibility. The teammate who only glances at a monitor still burns a $34 licence, and every new scheduled job moves you toward the next $20 heartbeat block.",
              "Flat means the invoice stays the same whether you watch three things or #{entry.uptime_monitors}. Going over an allowance blocks the next create until you remove something, never a surprise line on the invoice."
            ]
          },
          %{
            "heading" => "The line that changes",
            "body" => [
              "Keep the command and swap the URL. The exit code goes in the path, so a failed run reports a fail instead of nothing."
            ],
            "code" =>
              "# Before: Better Stack\n./backup.sh && curl -fsS https://uptime.betterstack.com/api/v1/heartbeat/YOUR_TOKEN\n\n# After: PostDeploy\n./backup.sh; curl -fsS https://ingest.postdeploy.dev/h/hb_YOUR_TOKEN/$?",
            "filename" => "job.sh",
            "language" => "shell"
          }
        ],
        why_looking: [
          "There is no plan to move to. Past the free tier you assemble a bill out of add-ons: responder seats, monitor blocks, heartbeat blocks, status pages and per-GB telemetry.",
          "The add-on prices surprise people. Removing Better Stack branding from a status page is $250 a month, per page. Password protection is $50 a month, per page.",
          "Heartbeats cost four times what monitors cost per unit: $0.50 per monitor per month against $2.00 per heartbeat per month.",
          "Free members cannot see monitors, incidents or status pages. Anyone who needs to look at a monitor consumes a responder licence."
        ],
        free_tier_rows: [
          %{
            "label" => "Uptime and API monitors",
            "them" => "10",
            "us" => "#{entry.uptime_monitors}",
            "edge" => "us"
          },
          %{
            "label" => "Cron and heartbeat jobs",
            "them" => "10",
            "us" => "#{entry.cron_jobs}",
            "edge" => "us"
          },
          %{
            "label" => "Alert channels",
            "them" => "Slack and email",
            "us" => "Email, Slack, Discord",
            "edge" => "us"
          },
          %{
            "label" => "Analytics in the same package",
            "them" => "Not offered",
            "us" => "Included",
            "edge" => "us"
          },
          %{
            "label" => "Pricing model past free",
            "them" => "Metered per seat, monitor, heartbeat and page",
            "us" => "One package, #{monthly_price}",
            "edge" => "us"
          }
        ],
        they_do_better: [],
        we_do_better: [
          "A price you can predict. PostDeploy is a flat #{monthly_price} for #{package.limits.projects} projects, #{package.limits.uptime_monitors} uptime monitors and #{package.limits.cron_jobs} cron jobs. On Better Stack's meter the same shape is monitor blocks plus heartbeat blocks plus a responder seat, each on its own line.",
          "Seats inside the package. PostDeploy covers #{Package.limit(:members)} members for #{PackagePresenter.price()} a month. Better Stack bills $34 a month for each responder.",
          "Cron jobs are not a premium unit. They have their own allowance in the same package; on Better Stack a heartbeat costs four times per unit what a monitor costs.",
          "Discord alerts are included in PostDeploy. Better Stack's free tier is Slack and email only.",
          "Cookieless analytics in the same package and the same projects, so the visitor numbers live next to the uptime history."
        ],
        stay_with_them: [],
        switch_to_us: [
          "Responder seats are most of your Better Stack bill.",
          "Your heartbeat count is climbing, $20 for every ten.",
          "You want to know next month's bill today.",
          "You want visitor numbers for the same project without another analytics vendor."
        ],
        migration: [
          "Export monitors through the REST API or the Terraform provider: check frequency, method, headers, body, keyword assertions and expected status codes.",
          "Let your agent recreate each check in PostDeploy through MCP.",
          "Swap every heartbeat URL (`uptime.betterstack.com/api/v1/heartbeat/<token>`) in its script or CI job. A `/fail` call becomes `?state=fail`, and an exit code goes in the URL path.",
          "Check that each job reports its own failure. A fail ping or a non-zero exit alerts at once, and a job that sends nothing sends no alert.",
          "Point alerts at email, Slack, Discord, a webhook or Telegram."
        ],
        unverified: [],
        faqs: [
          %{
            "q" => "How does PostDeploy compare with Better Stack's free tier?",
            "a" =>
              "PostDeploy has #{entry.uptime_monitors} uptime monitors and #{entry.cron_jobs} cron jobs against Better Stack's 10 and 10, adds Discord to email and Slack, and includes error tracking and analytics in the same package."
          },
          %{
            "q" => "What does Better Stack cost for two people?",
            "a" =>
              "$68 a month in responder seats, because free members cannot see monitors, incidents or status pages. Ten more heartbeats add $20. PostDeploy is #{PackagePresenter.price()} a month, flat, for #{Package.limit(:members)} members."
          }
        ],
        sources: [
          %{
            "label" => "Better Stack pricing",
            "url" => "https://betterstack.com/pricing",
            "retrieved" => "2026-08-03"
          },
          %{
            "label" => "Better Uptime",
            "url" => "https://betterstack.com/uptime",
            "retrieved" => "2026-08-03"
          },
          %{
            "label" => "Check frequency documentation",
            "url" => "https://betterstack.com/docs/uptime/check-frequency/",
            "retrieved" => "2026-08-03"
          },
          %{
            "label" => "Cron and heartbeat monitor documentation",
            "url" => "https://betterstack.com/docs/uptime/cron-and-heartbeat-monitor/",
            "retrieved" => "2026-08-03"
          },
          %{
            "label" => "Team roles documentation",
            "url" => "https://betterstack.com/docs/uptime/team-management/manage-roles/",
            "retrieved" => "2026-08-03"
          }
        ]
      },
      # Sources rendered below, checked 2026-08-19 on the vendor's own pages:
      # - https://plausible.io/#pricing — Starter EUR 9/month at 10k
      #   pageviews with monthly billing, one site, 30-day trial, no free
      #   plan; Growth EUR 14 (3 sites), Business EUR 19 (10 sites);
      #   funnels, ecommerce revenue attribution, GA import, saved
      #   segments per plan cards.
      %{
        slug: "plausible",
        path: "/alternatives/plausible",
        cluster: "comparison",
        intent: :commercial_investigation,
        primary_query: "plausible alternative",
        title: "Plausible alternative: uptime, cron, errors | PostDeploy",
        meta_description:
          "PostDeploy against Plausible: the same cookieless analytics, plus uptime checks, cron heartbeats and error tracking in one flat-priced package.",
        nav_label: "Plausible alternative",
        summary:
          "PostDeploy against Plausible: cookieless analytics on both sides, and the uptime, cron and error tracking Plausible does not sell, in one flat-priced package.",
        lastmod: ~D[2026-08-31],
        competitor_name: "Plausible",
        competitor_homepage: "https://plausible.io/",
        positioning:
          "Plausible sells lightweight, privacy-first, cookieless web analytics with a simple dashboard and EU hosting, as an alternative to Google Analytics.",
        tldr:
          "Plausible answers one question: who visited. PostDeploy answers that and three more for #{price} a month: is the site up, did a cron job fail, what broke. Plausible's entry plan covers one site. PostDeploy covers #{package.limits.projects} projects. Get the whole answer. Switch to PostDeploy.",
        body_sections: [
          %{
            "heading" => "Pricing, tier by tier",
            "body" => [
              # fact: Plausible pricing page, retrieved 2026-08-19
              "Plausible starts at EUR 9 a month on monthly billing: 10,000 pageviews, one site, a 30-day trial and no free plan underneath. Growth is EUR 14 for three sites. Business is EUR 19 for ten.",
              "PostDeploy is #{monthly_price}: #{PackagePresenter.thousands(entry.analytics_events_per_month)} analytics events a month across #{package.limits.projects} projects, plus #{entry.uptime_monitors} uptime monitors, #{entry.cron_jobs} cron jobs and #{PackagePresenter.thousands(entry.error_events_per_month)} error events. The #{Package.trial_days()}-day trial needs no card.",
              # fact: Plausible Growth tier, 3 sites at EUR 14, pricing page, retrieved 2026-08-19
              "Ship three sites and Plausible moves you to Growth at EUR 14 a month, for visitor numbers alone. The same three fit in one #{price} PostDeploy package that also checks each site answers, opens an incident when a scheduled job fails and groups what threw."
            ]
          },
          %{
            "heading" => "Per-site pricing meters the wrong unit",
            "body" => [
              "A project is a marketing page, an API, a worker and four scheduled jobs. Only one of those emits pageviews. PostDeploy counts per project, so the traffic graph, the uptime history and the error feed all describe the same thing.",
              "Cookieless counting is the same on both sides: no cookies, no raw IP stored, no persistent visitor identifier, no banner. The difference is what sits beside the graph: the uptime check, the failed job and the error that explain a drop in traffic."
            ]
          },
          %{
            "heading" => "The tag that changes",
            "body" => [
              "Remove the Plausible snippet and add this before the closing body tag. Your connected agent creates the source and returns the token. Only the hostname you register can send data."
            ],
            "code" =>
              "<script>\n  window.postdeployMeasure = window.postdeployMeasure || [];\n</script>\n<script\n  defer\n  src=\"https://ingest.postdeploy.dev/m.js?token=YOUR_MEASURE_TOKEN&v=20260910\"\n></script>",
            "filename" => "measure.html",
            "language" => "html"
          }
        ],
        why_looking: [
          "Analytics is one bill of several. Plausible's entry plan covers analytics for one site, and uptime, cron and errors still need their own tools.",
          "The entry plan includes one site. Each project you ship needs a bigger plan.",
          "You still need uptime checks, cron monitoring and error tracking somewhere else, each with its own login and invoice.",
          "There is no free plan, only a 30-day trial."
        ],
        free_tier_rows: [
          %{
            "label" => "Entry price",
            "them" => "EUR 9 a month, 10,000 pageviews, one site",
            "us" => "#{monthly_price} after the trial",
            "edge" => "us"
          },
          %{
            "label" => "Sites or projects on the entry plan",
            "them" => "1",
            "us" => "#{package.limits.projects}, during the trial and after it",
            "edge" => "us"
          },
          %{
            "label" => "Cookieless, no consent banner",
            "them" => "Yes",
            "us" => "Yes",
            "edge" => "even"
          },
          %{
            "label" => "Uptime and API monitors",
            "them" => "Not offered",
            "us" => "#{entry.uptime_monitors} in the package",
            "edge" => "us"
          },
          %{
            "label" => "Cron job monitoring",
            "them" => "Not offered",
            "us" => "#{entry.cron_jobs} in the package",
            "edge" => "us"
          },
          %{
            "label" => "Error tracking",
            "them" => "Not offered",
            "us" =>
              "#{PackagePresenter.thousands(entry.error_events_per_month)} events a month in the package",
            "edge" => "us"
          }
        ],
        they_do_better: [],
        we_do_better: [
          "More product per dollar. PostDeploy is #{monthly_price} and covers analytics plus uptime checks, cron heartbeats and error tracking for #{package.limits.projects} projects. Plausible's entry plan covers analytics for one site.",
          "A #{Package.trial_days()}-day free trial, then one flat price: #{PackagePresenter.thousands(entry.analytics_events_per_month)} analytics events a month for #{monthly_price}.",
          "One login for the whole project: the pageview graph, the uptime history and the error feed describe the same project.",
          "The same privacy model: no cookies, no raw IP storage and no persistent visitor identifier."
        ],
        stay_with_them: [],
        switch_to_us: [
          "Your analytics bill covers one site and you ship more than one project.",
          "You are about to add an uptime monitor or a cron monitor as a second subscription.",
          "You want one flat bill for the whole project instead of one per tool."
        ],
        migration: [
          "Swap the script tag: remove Plausible's snippet and add the PostDeploy analytics script per project.",
          "Re-wire custom events per event name.",
          "Point the rest of the project at the same login: uptime checks for the URLs and one curl line per scheduled job."
        ],
        unverified: [],
        faqs: [
          %{
            "q" => "Is PostDeploy analytics cookieless like Plausible?",
            "a" =>
              "Yes. No cookies, no raw IP stored, no persistent visitor identifier. The visitor hash uses a salt that rotates daily and is not reversible across days."
          },
          %{
            "q" => "How many analytics events does PostDeploy include?",
            "a" =>
              "#{PackagePresenter.thousands(entry.analytics_events_per_month)} a month, alongside #{entry.uptime_monitors} uptime monitors, #{entry.cron_jobs} cron jobs and #{PackagePresenter.thousands(entry.error_events_per_month)} error events."
          },
          %{
            "q" => "How fast can I switch from Plausible?",
            "a" =>
              "Swap one script tag per project. PostDeploy counts from the moment the new script loads."
          }
        ],
        sources: [
          %{
            "label" => "Plausible pricing",
            "url" => "https://plausible.io/#pricing",
            "retrieved" => "2026-08-19"
          }
        ]
      },
      # Sources rendered below, checked 2026-08-19 on the vendor's own pages:
      # - https://usefathom.com/pricing — USD 15/month at 100k pageviews
      #   (slider minimum), USD 45 at 500k; 50 sites on every plan;
      #   forever data retention; custom events count as pageviews;
      #   pricing FAQ states there is no free plan, 7-day trial only.
      # - https://usefathom.com/features and /docs — no uptime monitoring
      #   feature listed anywhere on either page.
      %{
        slug: "fathom",
        path: "/alternatives/fathom",
        cluster: "comparison",
        intent: :commercial_investigation,
        primary_query: "fathom analytics alternative",
        title: "Fathom Analytics alternative: monitoring included | PostDeploy",
        meta_description:
          "PostDeploy against Fathom Analytics: the same cookieless analytics, plus uptime checks, cron heartbeats and error tracking in one flat-priced package.",
        nav_label: "Fathom alternative",
        summary:
          "PostDeploy against Fathom Analytics: cookieless analytics on both sides, and the uptime, cron and error tracking Fathom does not sell.",
        lastmod: ~D[2026-08-31],
        competitor_name: "Fathom Analytics",
        competitor_homepage: "https://usefathom.com/",
        positioning:
          "Fathom Analytics sells privacy-first, cookieless website analytics with one simple dashboard, as a Google Analytics alternative, priced by monthly pageviews.",
        tldr:
          "Fathom sells analytics alone, from $15 a month, with no free plan and a seven-day trial. PostDeploy is #{monthly_price} and covers analytics plus uptime checks, cron heartbeats and error tracking, after #{Package.trial_days()} free days with no card. One package, four jobs. Switch to PostDeploy.",
        body_sections: [
          %{
            "heading" => "Pricing, tier by tier",
            "body" => [
              # fact: Fathom pricing page and pricing FAQ, retrieved 2026-08-19
              "Fathom's slider starts at $15 a month for 100,000 pageviews and reads $45 at 500,000. Custom events count against the same pageview number, so instrumenting more of your app moves the slider. Fathom's pricing FAQ confirms there is no free plan, only a seven-day trial.",
              "PostDeploy is #{monthly_price} for #{PackagePresenter.thousands(entry.analytics_events_per_month)} analytics events across #{package.limits.projects} projects, and carries #{entry.uptime_monitors} uptime monitors, #{entry.cron_jobs} cron jobs and #{PackagePresenter.thousands(entry.error_events_per_month)} error events too, after #{Package.trial_days()} free days with no card.",
              # fact: Fathom pricing page, 500,000 pageviews at $45 a month, retrieved 2026-08-19
              "A team doing 500,000 pageviews reads $45 on that meter, for analytics. PostDeploy is #{PackagePresenter.price()} a month: #{PackagePresenter.thousands(Package.limit(:analytics_events_per_month))} analytics events, #{Package.limit(:uptime_monitors)} uptime monitors, #{Package.limit(:cron_jobs)} cron jobs, #{PackagePresenter.thousands(Package.limit(:error_events_per_month))} error events and #{Package.limit(:members)} seats across #{Package.limit(:projects)} projects."
            ]
          },
          %{
            "heading" => "A pageview meter bills your best week",
            "body" => [
              "A pageview meter makes your best week your most expensive one. The launch lands, the post does numbers, the bill follows. Custom events push the same number up, so the team that tracks its signups pays for the diligence.",
              "PostDeploy prices per organisation instead: one flat package, and reaching an allowance never adds a line to the invoice.",
              "The analytics covers pageviews, top pages, referrers and named custom events, without cookies or a banner. The rest of the package is what a pageview meter never sells you: checks for when the site stops answering, an incident the moment a job reports a failure, and the error feed for the same project."
            ]
          },
          %{
            "heading" => "The tag that changes",
            "body" => [
              "Remove the Fathom snippet and add this before the closing body tag. Your connected agent creates the source and returns the token. Only the hostname you register can send data."
            ],
            "code" =>
              "<script>\n  window.postdeployMeasure = window.postdeployMeasure || [];\n</script>\n<script\n  defer\n  src=\"https://ingest.postdeploy.dev/m.js?token=YOUR_MEASURE_TOKEN&v=20260910\"\n></script>",
            "filename" => "measure.html",
            "language" => "html"
          }
        ],
        why_looking: [
          "There is no free plan; Fathom's own pricing FAQ says so. The trial runs a week, then the meter starts.",
          "Analytics is the only pillar. Uptime, cron monitoring and error tracking still need their own tools and invoices.",
          "$15 a month buys analytics alone. PostDeploy adds uptime checks, cron heartbeats and error tracking for the same projects."
        ],
        free_tier_rows: [
          %{
            "label" => "Entry price",
            "them" => "$15 a month, 100,000 pageviews",
            "us" => "#{monthly_price} after the trial",
            "edge" => "us"
          },
          %{
            "label" => "Cookieless, no consent banner",
            "them" => "Yes",
            "us" => "Yes",
            "edge" => "even"
          },
          %{
            "label" => "Uptime and API monitors",
            "them" => "Not offered",
            "us" => "#{entry.uptime_monitors} in the package",
            "edge" => "us"
          },
          %{
            "label" => "Cron job monitoring",
            "them" => "Not offered",
            "us" => "#{entry.cron_jobs} in the package",
            "edge" => "us"
          },
          %{
            "label" => "Error tracking",
            "them" => "Not offered",
            "us" =>
              "#{PackagePresenter.thousands(entry.error_events_per_month)} events a month in the package",
            "edge" => "us"
          }
        ],
        they_do_better: [],
        we_do_better: [
          "A #{Package.trial_days()}-day free trial with no credit card, with the same #{PackagePresenter.thousands(entry.analytics_events_per_month)} analytics events a month the subscription keeps afterwards.",
          "More product per dollar. PostDeploy is #{monthly_price} and adds uptime checks, cron heartbeats and error tracking to the analytics, on the same projects.",
          "One login for the whole project: visitor numbers, uptime history and the error feed describe the same project.",
          "No banner: no cookies, no raw IP stored, and a visitor hash whose salt rotates daily."
        ],
        stay_with_them: [],
        switch_to_us: [
          "You want analytics for a side project without paying on day one.",
          "You are about to add an uptime monitor or a cron monitor as a second subscription.",
          "You want one flat bill for the whole project instead of one per tool."
        ],
        migration: [
          "Swap the script tag: remove Fathom's snippet and add the PostDeploy analytics script per project.",
          "Re-wire custom events per event name. On both tools custom events count against the same allowance as pageviews.",
          "Point the rest of the project at the same login: uptime checks for the URLs and one curl line per scheduled job."
        ],
        unverified: [],
        faqs: [
          %{
            "q" => "Does Fathom Analytics have a free plan?",
            "a" =>
              "No. Fathom's pricing FAQ states there is no free option; plans start at $15 a month after a 7-day trial. PostDeploy gives you #{Package.trial_days()} free days with no card, then #{monthly_price}."
          },
          %{
            "q" => "Is PostDeploy analytics cookieless like Fathom?",
            "a" =>
              "Yes. No cookies, no raw IP stored, no persistent visitor identifier, so analytics needs no consent banner."
          },
          %{
            "q" => "What does PostDeploy add over Fathom for the price?",
            "a" =>
              "Uptime and API checks, cron heartbeat monitoring and error tracking in the same package and the same projects. Fathom sells analytics only."
          }
        ],
        sources: [
          %{
            "label" => "Fathom Analytics pricing",
            "url" => "https://usefathom.com/pricing",
            "retrieved" => "2026-08-19"
          },
          %{
            "label" => "Fathom Analytics features",
            "url" => "https://usefathom.com/features",
            "retrieved" => "2026-08-19"
          },
          %{
            "label" => "Fathom Analytics documentation",
            "url" => "https://usefathom.com/docs",
            "retrieved" => "2026-08-19"
          }
        ]
      },
      # Sources rendered below, checked 2026-08-19 on Google's own pages:
      # - https://support.google.com/analytics/answer/11397207 — GA4 sets
      #   first-party cookies (_ga, _ga_<container-id>, 2-year default).
      # - https://support.google.com/analytics/answer/7667196 — user-level
      #   data retention on standard properties: 2 or 14 months; longer
      #   windows are 360 only; retention limits explorations and funnels.
      %{
        slug: "google-analytics",
        path: "/alternatives/google-analytics",
        cluster: "comparison",
        intent: :commercial_investigation,
        primary_query: "google analytics alternative",
        title: "Google Analytics alternative: cookieless analytics | PostDeploy",
        meta_description:
          "PostDeploy against Google Analytics: cookieless analytics with no consent banner, plus uptime, cron and error tracking in one flat-priced package.",
        nav_label: "Google Analytics alternative",
        summary:
          "PostDeploy against Google Analytics: cookieless counting without a consent banner or a declined-consent gap, plus uptime, cron and error tracking.",
        lastmod: ~D[2026-09-09],
        competitor_name: "Google Analytics",
        competitor_homepage: "https://marketingplatform.google.com/about/analytics/",
        positioning:
          "Google Analytics is Google's web analytics product: event-based measurement, advertising integrations and BigQuery export, free of charge for standard properties.",
        tldr:
          "Google Analytics sets cookies, so an EU audience gets a consent banner and every visitor who declines drops out of your numbers. PostDeploy counts without cookies, needs no banner for analytics, and watches uptime, cron jobs and errors in the same package. Remove the banner. Switch to PostDeploy.",
        body_sections: [
          %{
            "heading" => "Pricing, tier by tier",
            "body" => [
              # fact: Google Analytics data retention documentation, retrieved 2026-08-19
              "Standard properties cost nothing. You pay in retention instead: user-level data on a standard property is kept for 2 or 14 months, and that cap reaches into explorations and funnel reports. Longer windows need a 360 purchase.",
              "PostDeploy is #{monthly_price} and keeps #{Package.limit(:measure_retention_days)} days of analytics. The #{Package.trial_days()}-day trial needs no card.",
              "Price the whole job. Free analytics says nothing about the API that fell over or the job that failed, so those arrive as two more signups and two more invoices. PostDeploy is #{price} a month for #{package.limits.projects} projects with #{entry.uptime_monitors} uptime monitors, #{entry.cron_jobs} cron jobs, #{PackagePresenter.thousands(entry.error_events_per_month)} error events and #{PackagePresenter.thousands(entry.analytics_events_per_month)} analytics events."
            ]
          },
          %{
            "heading" => "Consent banners cost you twice",
            "body" => [
              # fact: Google Analytics cookie documentation, _ga and _ga_<container-id>, 2-year default, retrieved 2026-08-19
              "GA4 sets first-party cookies, _ga and _ga_<container-id>, with a two-year default lifetime. Cookies mean a consent banner for an EU audience, and the banner costs twice: an interstitial before your product, and a hole in your numbers where everyone who declined used to be.",
              "PostDeploy sets no cookies, stores no raw IP and keeps no persistent visitor identifier. The visitor hash uses a salt that rotates daily. No banner to design, and no declined-consent hole in the count.",
              "Then there is time to answer. An advertising-shaped report surface puts several clicks between you and how many people came yesterday, from where. Measure puts that on one screen per project, beside its uptime history and error feed."
            ]
          },
          %{
            "heading" => "The tag that changes",
            "body" => [
              "Remove the Google Analytics snippet and add this before the closing body tag. Your connected agent creates the source and returns the token. Only the hostname you register can send data."
            ],
            "code" =>
              "<script>\n  window.postdeployMeasure = window.postdeployMeasure || [];\n</script>\n<script\n  defer\n  src=\"https://ingest.postdeploy.dev/m.js?token=YOUR_MEASURE_TOKEN&v=20260910\"\n></script>",
            "filename" => "measure.html",
            "language" => "html"
          }
        ],
        why_looking: [
          "Google Analytics sets cookies, so an EU audience means a consent banner, and every visitor who declines disappears from your numbers.",
          "User-level data retention on standard properties is capped at 14 months, and that cap limits explorations and funnel reports.",
          "The answer you open it for, how many people visited and from where, sits under layers of advertising-oriented reports.",
          "It measures the site. It does not tell you the site is down or a scheduled job failed."
        ],
        free_tier_rows: [
          %{
            "label" => "Price",
            "them" => "Free (standard properties)",
            "us" => "#{monthly_price} after the trial",
            "edge" => "even"
          },
          %{
            "label" => "Cookies and visitor identity",
            "them" => "First-party cookies and user-level reporting",
            "us" => "No analytics cookies or persistent visitor identifier",
            "edge" => "us"
          },
          %{
            "label" => "Analytics retention",
            "them" => "2 or 14 months on standard properties",
            "us" => "#{Package.limit(:measure_retention_days)} days",
            "edge" => "mixed"
          },
          %{
            "label" => "Setup",
            "them" => "Tag, consent tooling, banner",
            "us" => "One script tag",
            "edge" => "us"
          },
          %{
            "label" => "Uptime, cron and error tracking",
            "them" => "Not offered",
            "us" => "Included",
            "edge" => "us"
          }
        ],
        they_do_better: [],
        we_do_better: [
          "Cookieless analytics. PostDeploy sets no cookies, stores no raw IP and keeps no persistent visitor identifier.",
          "The traffic answer on one screen: pageviews, custom events and referrers per project, without report navigation.",
          "Monitoring in the same package: #{entry.uptime_monitors} uptime monitors, #{entry.cron_jobs} cron jobs and #{PackagePresenter.thousands(entry.error_events_per_month)} error events a month in the package, next to the visitor numbers.",
          "No consent banner for a cookieless count, so no interstitial in front of your product and no hole in the numbers where the visitors who declined used to be.",
          "Data that stays yours: one vendor, one login, and no advertising platform on the other end of the pageview."
        ],
        stay_with_them: [],
        switch_to_us: [
          "Your audience is in the EU and the consent banner costs you visitors and data.",
          "You open analytics to answer one question: is the site getting traffic, and from where.",
          "You also need to know the site is up and the scheduled jobs did not fail, without two more tools."
        ],
        migration: [
          "Swap the tag: remove the gtag or Tag Manager snippet and add the PostDeploy analytics script per project.",
          "Remove the consent banner for analytics if nothing else on the site needs one.",
          "Map the events you care about to named custom events.",
          "Point the rest of the project at the same login: uptime checks for the URLs and one curl line per scheduled job."
        ],
        unverified: [],
        faqs: [
          %{
            "q" => "How does PostDeploy pricing compare with Google Analytics?",
            "a" =>
              "Google Analytics covers analytics only. PostDeploy starts with #{Package.trial_days()} free days and no credit card, then #{monthly_price}: #{PackagePresenter.thousands(entry.analytics_events_per_month)} analytics events a month plus uptime, cron and error tracking."
          },
          %{
            "q" => "Do I still need a cookie banner with PostDeploy?",
            "a" =>
              "Not for analytics. PostDeploy sets no cookies and stores no raw IP or persistent visitor identifier. If other tools on your site set cookies, those still need consent."
          },
          %{
            "q" => "Do I need Google Tag Manager or consent tooling?",
            "a" =>
              "No. PostDeploy analytics is one script tag per project, with no consent tooling for the count."
          }
        ],
        sources: [
          %{
            "label" => "Google Analytics cookie usage",
            "url" => "https://support.google.com/analytics/answer/11397207",
            "retrieved" => "2026-08-19"
          },
          %{
            "label" => "Google Analytics data retention",
            "url" => "https://support.google.com/analytics/answer/7667196",
            "retrieved" => "2026-08-19"
          }
        ]
      }
    ]
  end
end
