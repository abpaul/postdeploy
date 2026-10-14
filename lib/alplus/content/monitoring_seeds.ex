defmodule Alplus.Content.MonitoringSeeds do
  @moduledoc """
  The monitoring search cluster and the high-intent heartbeat guides
  (BUILD.md Phase 4, the first organic traffic wedge).

  Every capability claim here is checked against the code by
  `AlplusWeb.Marketing.ProductTruthTest` and
  `AlplusWeb.Marketing.ProductFacts`. Anything PostDeploy does not do is stated as
  such rather than omitted, because a comparison a reader can falsify costs
  more trust than a gap they were warned about.

  These pages are `Alplus.Content.Guide` rows, which is the resource the
  public guide template already renders. They differ from the two original
  pillar guides only in intent: `/monitoring/*` answers commercial queries
  and `/guides/*` answers a technical problem well enough to be useful to
  someone who never signs up.

  Seeded separately from `Alplus.Content.Seeds` to keep each module
  readable; `Seeds.run/0` calls this one.
  """

  alias Alplus.Billing.Package
  alias AlplusWeb.Marketing.PackagePresenter
  alias Alplus.Content

  @lastmod ~D[2026-08-19]
  @heartbeat_guide_lastmod ~D[2026-09-04]
  @content_corrected_on ~D[2026-09-09]

  # The real, already-public author identity (the footer links @hasieratik).
  # Never invent a byline: fabricated authorship is worse than none.
  @author "Paul"

  # The ingest origin every heartbeat example pings. Kept in one place so a
  # host change cannot leave half the examples pointing somewhere dead.
  @ingest "https://ingest.postdeploy.dev"

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

  defp guides do
    [
      monitoring_hub(),
      uptime_monitoring(),
      cron_monitoring(),
      api_monitoring(),
      github_actions_guide(),
      kubernetes_cronjob_guide(),
      heroku_scheduler_guide(),
      systemd_timer_guide(),
      laravel_scheduler_guide(),
      airflow_guide(),
      gitlab_ci_schedule_guide()
    ]
  end

  # -- /monitoring -------------------------------------------------------

  defp monitoring_hub do
    trial_uptime_monitors = Package.limit(:uptime_monitors)
    trial_cron_jobs = Package.limit(:cron_jobs)

    trial_interval =
      PackagePresenter.interval_label(Package.limit(:min_check_interval_seconds))

    trial_retention_days = Package.limit(:detailed_uptime_retention_days)

    %{
      slug: "monitoring",
      path: "/monitoring",
      cluster: "monitoring",
      intent: :commercial_investigation,
      primary_query: "monitoring for small software teams",
      title: "Monitoring for small software teams | PostDeploy",
      meta_description:
        "Uptime, API and cron-job monitoring for one project, in one package. What PostDeploy checks, what it does not, and how to start on the #{Package.trial_days()}-day free trial.",
      nav_label: "Monitoring",
      summary:
        "The PostDeploy monitoring hub: uptime and API checks, cron and heartbeat jobs, what the package includes, and what PostDeploy deliberately does not do.",
      hero_badge: "#{Package.trial_days()}-day free trial, no credit card",
      hero_heading: "Know when your site, API or scheduled job breaks",
      hero_description:
        "PostDeploy checks your URLs and APIs on a schedule and records the pings your scheduled jobs send. It is for developers who run their own production app. A connected coding agent creates the monitors. The trial includes #{Package.limit(:uptime_monitors)} uptime and API monitors and #{Package.limit(:cron_jobs)} cron and heartbeat jobs, with no credit card.",
      cta_heading: "Monitor the project you just shipped",
      cta_label: "Start monitoring",
      related_paths: [
        %{"path" => "/monitoring/uptime", "label" => "Uptime monitoring: how HTTP checks work"},
        %{"path" => "/tools/website-health-check", "label" => "Website health check"},
        %{"path" => "/monitoring/cron-jobs", "label" => "Cron job monitoring with heartbeats"},
        %{
          "path" => "/monitoring/api",
          "label" => "API monitoring with keyword and status assertions"
        },
        %{
          "path" => "/guides/github-actions-heartbeat",
          "label" => "Guide: monitor a GitHub Actions schedule"
        },
        %{
          "path" => "/guides/kubernetes-cronjob-heartbeat",
          "label" => "Guide: monitor a Kubernetes CronJob"
        },
        %{
          "path" => "/guides/heroku-scheduler-heartbeat",
          "label" => "Guide: monitor a Heroku Scheduler job"
        },
        %{
          "path" => "/guides/systemd-timer-heartbeat",
          "label" => "Guide: monitor a systemd timer"
        },
        %{
          "path" => "/guides/laravel-scheduler-heartbeat",
          "label" => "Guide: monitor Laravel Scheduler"
        },
        %{
          "path" => "/guides/airflow-heartbeat",
          "label" => "Guide: monitor an Apache Airflow DAG"
        },
        %{
          "path" => "/guides/gitlab-ci-schedule-heartbeat",
          "label" => "Guide: monitor a GitLab CI schedule"
        },
        %{
          "path" => "/guides/backup-heartbeat",
          "label" => "Guide: monitor a scheduled backup"
        },
        %{"path" => "/pricing", "label" => "Pricing and limits"}
      ],
      lastmod: @content_corrected_on,
      body_sections: [
        %{
          "heading" => "Example setup",
          "transcript" => %{
            "project" => "my-saas",
            "prompt" =>
              "Watch my-saas.com and its API every minute. Make the nightly backup report a failure.",
            "actions" => [
              ["monitor.create", "my-saas.com, HTTP check, every minute"],
              ["monitor.create", "api.my-saas.com/health, keyword check"],
              ["monitor.create", "nightly-backup, heartbeat, daily"]
            ],
            "result" => "Added to my-saas. Review the monitors in PostDeploy."
          }
        },
        %{
          "heading" => "What PostDeploy monitors",
          "body" => [
            "Two questions cover most of what breaks in a small production system. Is the thing you serve responding? Did the job you scheduled finish? PostDeploy answers both in one project."
          ],
          "list" => [
            "Uptime checks (HTTP): request a URL on a schedule and open an incident when it fails or times out.",
            "Keyword checks: the same request, plus an assertion that the response body does or does not contain a string.",
            "API checks: methods, headers and request bodies, with expected status codes.",
            "TCP checks: open a connection to a host and port, for services that are not HTTP.",
            "DNS checks: resolve a record and assert the answer.",
            "Heartbeats: your scheduled job reports start, finish or failure to PostDeploy.",
            "SSL and domain expiry warnings: sent 14, 7 and 1 days ahead."
          ]
        },
        %{
          "heading" => "How setup works",
          "body" => [
            "A coding agent connected to PostDeploy creates the monitors. You review them in the dashboard. After setup, your own code calls plain URLs, and no agent runs in production."
          ],
          "list" => [
            "1. Connect your coding agent to PostDeploy. You approve what it can read and change in the browser.",
            "2. Ask it to create the monitors, for example an HTTP check on your site and a heartbeat for your nightly job.",
            "3. Add the heartbeat line it gives you to the job. The line below reports the exit code."
          ],
          "code" => "/opt/backup.sh; curl -fsS \"#{@ingest}/h/$POSTDEPLOY_HEARTBEAT_TOKEN/$?\""
        },
        %{
          "heading" => "Limits",
          "list" => [
            "No ICMP ping checks and no UDP checks.",
            "No browser or multi-step transaction checks.",
            "Checks run from one location. PostDeploy cannot confirm a failure from a second location before it alerts.",
            "A heartbeat that stops arriving sends no alert. A run that never starts sends nothing, so PostDeploy cannot report it. A job on an interval schedule shows as Late on the Monitor screen.",
            "No on-call rotation or escalation policy. PostDeploy opens an incident and notifies your channels."
          ]
        },
        %{
          "heading" => "How a check becomes an alert",
          "body" => [
            "A check runs on your interval. The failure threshold defaults to 2 consecutive failures and you can set it from 1 to 5, so a single blip does not wake you. Recovery needs 2 consecutive passes.",
            "When the threshold is crossed, PostDeploy opens an incident and notifies every channel you set up: email, Slack, Discord, webhook or Telegram. Acknowledging an incident stops reminders without closing it. Uptime comes from incident times, and paused time counts on neither side."
          ]
        },
        %{
          "heading" => "Where to start",
          "body" => [
            "If you serve a URL, start with an uptime check. If you schedule a job, add a heartbeat. The two allowances are separate, so a heartbeat never uses an uptime monitor."
          ]
        }
      ],
      faqs: [
        %{
          "q" => "How many monitors does the trial include?",
          "a" =>
            "#{trial_uptime_monitors} uptime and API monitors and #{trial_cron_jobs} cron and heartbeat jobs, on separate allowances, with a #{trial_interval} minimum check interval and #{trial_retention_days} days of detailed check samples."
        },
        %{
          "q" => "Do I need a coding agent?",
          "a" =>
            "A connected coding agent creates the monitors and tokens, and you review them in the dashboard. The free website health check can also start a continuous URL check without an agent. The heartbeat line the agent gives you is plain curl, and any scheduler that can make an HTTPS request runs it."
        },
        %{
          "q" => "Does PostDeploy check from more than one location?",
          "a" =>
            "No. Checks run from one location, so PostDeploy cannot confirm an outage from a second location before it alerts. A network problem on the path to your app can read as downtime. Set the failure threshold above 1 so a short blip does not alert."
        },
        %{
          "q" => "What is the difference between an uptime check and a heartbeat?",
          "a" =>
            "An uptime check is PostDeploy asking your URL whether it is alive. A heartbeat is your job reporting that it started, finished or failed. A heartbeat that stops arriving sends no alert. On an interval schedule it shows as Late on the Monitor screen."
        }
      ]
    }
  end

  # -- /monitoring/uptime ------------------------------------------------

  defp uptime_monitoring do
    %{
      slug: "monitoring-uptime",
      path: "/monitoring/uptime",
      cluster: "uptime",
      intent: :commercial_investigation,
      primary_query: "uptime monitoring",
      title: "Uptime monitoring: HTTP checks and incidents | PostDeploy",
      meta_description:
        "How PostDeploy uptime monitoring works: HTTP and keyword checks, failure thresholds, incidents, and time-weighted uptime. #{Package.limit(:uptime_monitors)} monitors on the trial.",
      nav_label: "Uptime monitoring",
      summary:
        "How PostDeploy runs HTTP uptime checks, when a failure becomes an incident, and how uptime is calculated.",
      hero_badge: "#{Package.trial_days()}-day free trial, no credit card",
      hero_heading: "Know when your site or API stops answering",
      hero_description:
        "PostDeploy requests your URL on a schedule and opens an incident when the check fails or times out. It is for developers who run their own site or API. You set the failure threshold, and uptime comes from incident times.",
      cta_heading: "Ask your agent for an uptime check",
      cta_label: "Start monitoring",
      related_paths: [
        %{"path" => "/monitoring", "label" => "All PostDeploy monitoring"},
        %{"path" => "/tools/website-health-check", "label" => "Website health check"},
        %{"path" => "/monitoring/api", "label" => "API monitoring"},
        %{"path" => "/monitoring/cron-jobs", "label" => "Cron job monitoring"},
        %{"path" => "/free-uptime-monitoring", "label" => "What the free uptime trial covers"},
        %{
          "path" => "/alternatives/uptimerobot",
          "label" => "PostDeploy compared with UptimeRobot"
        }
      ],
      lastmod: @lastmod,
      body_sections: [
        %{
          "heading" => "Example setup",
          "transcript" => %{
            "project" => "my-saas",
            "prompt" =>
              "Check my-saas.com every minute. Open an incident after two failed checks.",
            "actions" => [
              ["monitor.create", "my-saas.com, HTTP check, every minute"]
            ],
            "result" =>
              "Review the check in PostDeploy. SSL and domain expiry warnings come with it."
          }
        },
        %{
          "heading" => "Set up an uptime check",
          "body" => [
            "A coding agent connected to PostDeploy creates the check. You review it in the dashboard."
          ],
          "list" => [
            "1. Connect your coding agent to PostDeploy and choose the project.",
            "2. Ask it to create an HTTP monitor for your URL. The agent runs `monitor.create` with the type http.",
            "3. Open the monitor in the dashboard to read its checks and incidents."
          ]
        },
        %{
          "heading" => "What an uptime check does",
          "body" => [
            "Each check makes one HTTP request to your URL on the interval you choose, and records the status code and the response time. You choose the method, headers, redirect handling and timeout.",
            "A keyword check adds one assertion: the response body must contain, or must not contain, a string you set. It catches a server that returns 200 with an error page or an empty template.",
            "TCP and DNS checks cover services that are not HTTP."
          ]
        },
        %{
          "heading" => "When a failure becomes an incident",
          "body" => [
            "The failure threshold defaults to 2 consecutive failures and you can set it from 1 to 5. A low value catches short outages. A high value avoids alerts for a blip. Recovery needs 2 consecutive passes, so a flapping endpoint does not resolve and reopen repeatedly.",
            "When an incident opens, every channel on the monitor is notified. Acknowledging stops reminders without closing the incident. To be reminded while it is open, set the monitor to resend after a number of failed checks."
          ]
        },
        %{
          "heading" => "How uptime is calculated",
          "body" => [
            "Uptime is time-weighted from incident start and end times, not a ratio of failed to total check rows. The two disagree when the interval changes or a check is missed. The incident-based number matches what your users experienced.",
            "Paused time counts on neither side. Pausing a monitor during planned maintenance neither raises nor lowers your uptime."
          ]
        },
        %{
          "heading" => "Check intervals and retention",
          "body" => [
            "The shortest interval is #{PackagePresenter.interval_label(Package.limit(:min_check_interval_seconds))}, on the trial and after it. An outage can run for about one interval before the first failed check.",
            "Individual check results are kept for #{Package.limit(:detailed_uptime_retention_days)} days. After that they fold into daily uptime history."
          ]
        },
        %{
          "heading" => "Limits",
          "list" => [
            "No ICMP ping checks and no UDP checks.",
            "No browser checks, so a login flow in a real browser cannot be checked.",
            "Checks run from one location. PostDeploy cannot confirm a failure from a second location before it alerts."
          ]
        }
      ],
      faqs: [
        %{
          "q" => "How quickly will PostDeploy notice an outage?",
          "a" =>
            "With the default threshold of 2, an alert follows the second failed check, so about two check intervals after the outage starts. Set the threshold to 1 to alert on the first failure, at the cost of more false alarms."
        },
        %{
          "q" => "Can PostDeploy check a page behind authentication?",
          "a" =>
            "Yes, if the authentication fits in a header or a request body. You set the method, headers and body on the check. A login flow that needs a real browser cannot be checked."
        },
        %{
          "q" => "Does a slow response count as down?",
          "a" =>
            "Only if it exceeds the timeout you set on the check, and then the check fails. PostDeploy records the response time of every check. A response that only got slower opens no incident."
        }
      ]
    }
  end

  # -- /monitoring/cron-jobs ---------------------------------------------

  defp cron_monitoring do
    %{
      slug: "monitoring-cron-jobs",
      path: "/monitoring/cron-jobs",
      cluster: "cron",
      intent: :commercial_investigation,
      primary_query: "cron job monitoring",
      title: "Cron job monitoring with heartbeats | PostDeploy",
      meta_description:
        "Record scheduled job completion and explicit failures with a heartbeat URL. #{Package.limit(:cron_jobs)} cron jobs on the PostDeploy trial.",
      nav_label: "Cron job monitoring",
      summary:
        "How PostDeploy heartbeat monitoring records scheduled job completion and explicit failures, and what a missing ping does.",
      hero_badge: "#{Package.trial_days()}-day free trial, no credit card",
      hero_heading: "Know when a scheduled job fails",
      hero_description:
        "Add one curl line to a cron job, CI schedule or scheduled task. PostDeploy records when the job starts, finishes or fails. A failure opens an incident at once and notifies your alert channels.",
      cta_heading: "Ask your agent to create a heartbeat",
      cta_label: "Start monitoring",
      related_paths: [
        %{"path" => "/docs/monitoring/heartbeats", "label" => "Heartbeat protocol reference"},
        %{"path" => "/monitoring", "label" => "All PostDeploy monitoring"},
        %{"path" => "/guides", "label" => "All heartbeat guides"},
        %{"path" => "/guides/backup-heartbeat", "label" => "Guide: monitor a scheduled backup"},
        %{
          "path" => "/guides/github-actions-heartbeat",
          "label" => "Guide: GitHub Actions scheduled workflows"
        },
        %{
          "path" => "/guides/kubernetes-cronjob-heartbeat",
          "label" => "Guide: Kubernetes CronJob"
        },
        %{"path" => "/free-cron-job-monitoring", "label" => "What the free cron trial covers"},
        %{"path" => "/alternatives/cronitor", "label" => "PostDeploy compared with Cronitor"},
        %{
          "path" => "/alternatives/healthchecks-io",
          "label" => "PostDeploy compared with Healthchecks.io"
        }
      ],
      lastmod: @lastmod,
      body_sections: [
        %{
          "heading" => "Example setup",
          "transcript" => %{
            "project" => "my-saas",
            "prompt" =>
              "Watch the nightly backup. It runs every day at 03:00 and reports its exit code.",
            "actions" => [
              ["monitor.create", "nightly-backup, heartbeat, daily at 03:00"]
            ],
            "result" => "The agent shows the heartbeat URL once. Add it after the job's command."
          }
        },
        %{
          "heading" => "Set up a heartbeat",
          "body" => [
            "A coding agent connected to PostDeploy creates the heartbeat monitor and its token. Your job then makes one plain HTTPS request.",
            "In the line below, `-f` makes curl fail on an HTTP error, `-s` hides progress output and `-S` still prints errors. That suits cron, where any output becomes mail."
          ],
          "list" => [
            "1. Connect your coding agent to PostDeploy and choose the project.",
            "2. Ask it to create a heartbeat monitor for the job, with the expected interval. The agent runs `monitor.create` with the type heartbeat and shows you the token.",
            "3. Store the token as a secret. It starts with `hb_` and PostDeploy shows it once.",
            "4. Add the heartbeat line to the job, as in the crontab below."
          ],
          "code" =>
            "POSTDEPLOY_HEARTBEAT_URL=#{@ingest}/h/hb_YOUR_TOKEN\n0 3 * * * /opt/backup.sh; curl -fsS \"$POSTDEPLOY_HEARTBEAT_URL/$?\"",
          "filename" => "crontab"
        },
        %{
          "heading" => "What each ping records",
          "body" => [
            "The exit code in the URL sets the outcome. Use `;` between the job and the ping, because the ping must run whether or not the job succeeded."
          ],
          "list" => [
            "Exit code 0, or `?state=finish`, or no state: records an Up check. An open incident resolves after two passes in a row.",
            "Any other exit code, or `?state=fail`: records a Down check, opens an incident at once and notifies your alert channels.",
            "`?state=start`: marks the run as started and records no check. If the monitor has an expected duration and a started run never finishes, the next ping records it as hung."
          ],
          "code" =>
            "curl -fsS \"#{@ingest}/h/$POSTDEPLOY_HEARTBEAT_TOKEN?state=start\"\n/opt/backup.sh\ncurl -fsS \"#{@ingest}/h/$POSTDEPLOY_HEARTBEAT_TOKEN/$?\"",
          "filename" => "backup-wrapper.sh"
        },
        %{
          "heading" => "What a heartbeat does not catch",
          "body" => [
            "A missing ping opens no incident and sends no alert. A run that never starts sends nothing, so PostDeploy cannot report it. After at least one check, a monitor on an interval schedule with no ping for twice its interval, and at least 5 minutes, shows Late on the Monitor screen.",
            "A job that runs and fails is reported at once. Send the failure from the job wrapper wherever the job can fail. The [heartbeat reference](/docs/monitoring/heartbeats#missed-runs) has the full rules."
          ]
        },
        %{
          "heading" => "Test the heartbeat",
          "body" => [
            "Send one request from the environment that runs the job. A recognised token returns 202. A 404 means the token is wrong. If the request cannot connect, check the runner's outbound network access."
          ],
          "code" =>
            "curl -i \"#{@ingest}/h/$POSTDEPLOY_HEARTBEAT_TOKEN\"\n# Expect: HTTP/1.1 202 Accepted"
        },
        %{
          "heading" => "What the ping accepts",
          "body" => [
            "GET and POST behave the same, so wget, `fetch()` or any HTTP client works as curl does. The `hb_` token is the only authentication, so treat the URL as a secret and send no header.",
            "A recognised token returns 202, including when the monitor is paused, and nothing is recorded. An unrecognised token returns 404."
          ]
        }
      ],
      faqs: [
        %{
          "q" => "What happens if my job never runs?",
          "a" =>
            "An interval-scheduled monitor shows Late on the Monitor screen. No incident opens and no alert is sent, because a run that never starts sends nothing. A job that starts and fails is reported at once."
        },
        %{
          "q" => "Do I need a coding agent?",
          "a" =>
            "A connected coding agent creates the heartbeat monitor and its token. The heartbeat line it gives you is plain curl. Any scheduler that can make an HTTPS request runs it, and nothing is installed on the server."
        },
        %{
          "q" => "Does a heartbeat use one of my uptime monitors?",
          "a" =>
            "No. Cron and heartbeat jobs have their own allowance, #{Package.limit(:cron_jobs)} in the package and the trial, separate from the #{Package.limit(:uptime_monitors)} uptime and API monitors."
        },
        %{
          "q" => "Can I report why a job failed?",
          "a" =>
            "You can send a short message with the ping as a msg query parameter, and the exit code through the path form. PostDeploy does not capture the job's full output or logs."
        }
      ]
    }
  end

  # -- /monitoring/api ---------------------------------------------------

  defp api_monitoring do
    %{
      slug: "monitoring-api",
      path: "/monitoring/api",
      cluster: "api",
      intent: :commercial_investigation,
      primary_query: "api monitoring",
      title: "API monitoring with status and keyword checks | PostDeploy",
      meta_description:
        "Monitor an API endpoint: set method, headers and body, assert the status code, and check the response body for a keyword. Included in the PostDeploy trial.",
      nav_label: "API monitoring",
      summary:
        "How to monitor an HTTP API with PostDeploy: request shape, status assertions, keyword assertions on the response body, and the limits.",
      hero_badge: "#{Package.trial_days()}-day free trial, no credit card",
      hero_heading: "Know when your API returns the wrong answer",
      hero_description:
        "An API that returns 200 with an error body is still broken. PostDeploy sends the request you define, expects the status code you set, and can assert that the response body contains or lacks a string. It is for developers who run their own API.",
      cta_heading: "Ask your agent to monitor your API",
      cta_label: "Start monitoring",
      related_paths: [
        %{"path" => "/monitoring", "label" => "All PostDeploy monitoring"},
        %{"path" => "/monitoring/uptime", "label" => "Uptime monitoring"},
        %{"path" => "/monitoring/cron-jobs", "label" => "Cron job monitoring"},
        %{"path" => "/pricing", "label" => "Pricing and limits"}
      ],
      lastmod: @lastmod,
      body_sections: [
        %{
          "heading" => "Example setup",
          "transcript" => %{
            "project" => "my-saas",
            "prompt" =>
              "Check api.my-saas.com/health every minute. Fail when the response body does not contain \"database\":\"up\".",
            "actions" => [
              ["monitor.create", "api.my-saas.com/health, keyword check, every minute"]
            ],
            "result" =>
              "Review the check in PostDeploy. Failures open an incident and notify your channels."
          }
        },
        %{
          "heading" => "Set up an API check",
          "body" => [
            "A coding agent connected to PostDeploy creates the check. You review it in the dashboard."
          ],
          "list" => [
            "1. Connect your coding agent to PostDeploy and choose the project.",
            "2. Give it the URL, method, headers, body and expected status code. Add the string the response must contain, or must not contain, for a keyword check.",
            "3. The agent runs `monitor.create` with the type http or keyword. Open the monitor in the dashboard to read its checks."
          ]
        },
        %{
          "heading" => "Check the answer, not just the connection",
          "body" => [
            "For an API, the useful question is whether a request returns the right data. A health endpoint that reports its dependencies is a better target than the root URL. It fails when the database is gone, not only when the web tier is.",
            "A keyword check asserts on the response body, which catches an endpoint that answers but reports a failure."
          ]
        },
        %{
          "heading" => "A practical health endpoint check",
          "body" => [
            "Assert on something that is only true when the dependencies are reachable. A body that contains \"ok\" is a weak signal if your error page also contains the word. Prefer a distinctive marker.",
            "Send the same request the monitor will make, and read the response before you rely on the check."
          ],
          "code" =>
            "curl -i -H 'Accept: application/json' https://api.example.com/health\n\n# Expect: HTTP/1.1 200 and a body containing \"database\":\"up\""
        },
        %{
          "heading" => "Authentication and secrets",
          "body" => [
            "Send a token in a request header on the check. Use a credential scoped to read-only health data, not a production admin key. PostDeploy stores it and replays it on every check."
          ]
        },
        %{
          "heading" => "Limits",
          "list" => [
            "No JSON path assertions, no schema validation and no chained multi-step requests. A check is one request with a status expectation and an optional substring assertion on the body.",
            "No browser login flows. An endpoint behind an interactive flow cannot be checked.",
            "Checks run from one location. PostDeploy cannot confirm a failure from a second location before it alerts.",
            "To assert on one JSON field, expose that condition as a distinctive string in an endpoint's response."
          ]
        }
      ],
      faqs: [
        %{
          "q" => "Can PostDeploy assert on a JSON field?",
          "a" =>
            "Not directly. Assertions are substring matches on the response body, so you can assert on a distinctive fragment such as \"database\":\"up\", but there is no JSON path expression or schema validation."
        },
        %{
          "q" => "Does an API check count against uptime monitors or cron jobs?",
          "a" =>
            "Uptime monitors. API and uptime checks share one allowance, #{Package.limit(:uptime_monitors)} on the trial. Cron and heartbeat jobs are counted separately."
        },
        %{
          "q" => "Can I monitor a POST endpoint?",
          "a" =>
            "Yes. You can set the method, headers and request body. Point it at something idempotent: the check will replay that request on every interval, indefinitely."
        }
      ]
    }
  end

  # -- /guides/github-actions-heartbeat ----------------------------------

  defp github_actions_guide do
    %{
      slug: "github-actions-heartbeat",
      path: "/guides/github-actions-heartbeat",
      cluster: "cron",
      intent: :informational,
      primary_query: "github actions scheduled workflow not running",
      title: "Monitor a GitHub Actions scheduled workflow | PostDeploy",
      meta_description:
        "GitHub disables scheduled workflows after 60 days of repository inactivity and delays cron runs under load. Report successful and failed runs with a heartbeat.",
      nav_label: "GitHub Actions heartbeat",
      summary:
        "Why GitHub Actions scheduled workflows silently stop, how to report completed and failed runs, and when an external watchdog is required.",
      hero_badge: "Guide",
      hero_heading: "Monitor a GitHub Actions scheduled workflow",
      hero_description:
        "A scheduled workflow can stop running without failing. GitHub disables schedules in repositories with no activity for 60 days, and delays or drops runs when the shared cron queue is busy. Neither produces a failed run to notice, because there is no run.",
      cta_heading: "Ask a connected MCP client to create this heartbeat",
      cta_label: "Create a heartbeat",
      # Editorial content making claims about third-party software, so it
      # carries a byline and the date those external facts were checked.
      author_name: @author,
      published_on: @lastmod,
      last_verified_on: @lastmod,
      # SITE-ARCHITECTURE.md §8 publish gate.
      platform: "GitHub Actions",
      docs_host: "docs.github.com",
      platform_failure_mode:
        "GitHub disables a scheduled workflow after 60 days without repository activity, and delays or drops scheduled runs when the shared runner queue is busy. Neither produces a failed run.",
      sources: [
        %{
          "label" => "Events that trigger workflows: schedule",
          "url" =>
            "https://docs.github.com/en/actions/using-workflows/events-that-trigger-workflows#schedule",
          "retrieved" => "2026-09-04"
        }
      ],
      not_offered: [
        "PostDeploy does not read GitHub Actions run logs",
        "PostDeploy does not restart or re-run a failed workflow",
        "PostDeploy does not track workflow duration, minutes usage or cost"
      ],
      code_verified_on: ~D[2026-09-04],
      related_paths: [
        %{"path" => "/docs/monitoring/heartbeats", "label" => "Heartbeat protocol reference"},
        %{"path" => "/monitoring/cron-jobs", "label" => "How cron job monitoring works"},
        %{
          "path" => "/guides/kubernetes-cronjob-heartbeat",
          "label" => "The same problem on Kubernetes"
        },
        %{"path" => "/monitoring", "label" => "All PostDeploy monitoring"}
      ],
      lastmod: @content_corrected_on,
      body_sections: [
        %{
          "heading" => "The failure this catches",
          "body" => [
            "A workflow with an on.schedule trigger has two failure modes that produce no failed run. GitHub disables scheduled workflows in a public repository after 60 days without commits, which is easy to hit on a stable automation repo. Separately, scheduled runs are queued on shared infrastructure and can be delayed, particularly on the hour, and a run that is delayed long enough may be dropped.",
            "In both cases the Actions tab shows no failure, because nothing ran. PostDeploy records a heartbeat only when a request arrives. Use an external watchdog when a skipped or delayed workflow needs an alert."
          ]
        },
        %{
          "heading" => "Add the ping",
          "body" => [
            "Ask a connected MCP client to create the heartbeat, then store its returned token as a repository secret named POSTDEPLOY_HEARTBEAT_TOKEN.",
            "Put the ping in its own step at the end of the job. It runs only if every previous step succeeded, which is the behaviour you want: a failed build should not report a healthy run."
          ],
          "code" => """
          name: Nightly sync
          on:
            schedule:
              # 03:17 rather than 03:00: on-the-hour schedules queue behind
              # everyone else's and are the most likely to be delayed.
              - cron: "17 3 * * *"
            workflow_dispatch:

          jobs:
            sync:
              runs-on: ubuntu-latest
              steps:
                - uses: actions/checkout@v4

                - name: Run the sync
                  run: ./scripts/sync.sh

                - name: Report success to PostDeploy
                  run: curl -fsS "$POSTDEPLOY_INGEST_URL/h/$POSTDEPLOY_HEARTBEAT_TOKEN"
                  env:
                    POSTDEPLOY_INGEST_URL: #{@ingest}
                    POSTDEPLOY_HEARTBEAT_TOKEN: ${{ secrets.POSTDEPLOY_HEARTBEAT_TOKEN }}
          """
        },
        %{
          "heading" => "Reporting failures too",
          "body" => [
            "The step above is skipped when an earlier step fails, so it records no result. To alert the moment a run fails, add a second step that runs on failure and reports a non-zero exit code.",
            "if: failure() runs the step only when a previous step failed. The /1 path segment reports a failing exit code, which opens an incident immediately rather than waiting for the schedule to lapse."
          ],
          "code" => """
          - name: Report failure to PostDeploy
            if: failure()
            run: curl -fsS "$POSTDEPLOY_INGEST_URL/h/$POSTDEPLOY_HEARTBEAT_TOKEN/1"
            env:
              POSTDEPLOY_INGEST_URL: #{@ingest}
              POSTDEPLOY_HEARTBEAT_TOKEN: ${{ secrets.POSTDEPLOY_HEARTBEAT_TOKEN }}
          """
        },
        %{
          "heading" => "Check it works before you trust it",
          "body" => [
            "A monitor you never tested is a monitor you are guessing about. Trigger the workflow manually with workflow_dispatch, which the example enables, and confirm the monitor moved to a passing state in PostDeploy.",
            "Then test the failure path, because that is the one you actually care about. Temporarily make the job exit non-zero, run it, and confirm you receive the alert. A successful ping proves the token and network path; only a failed run proves the alert reaches you."
          ],
          "code" => """
          # Verify the token and URL from your terminal first.
          curl -i "#{@ingest}/h/hb_YOUR_TOKEN"
          # Expect: HTTP/2 202 with an empty body.
          # A 404 means the token is wrong or the monitor was deleted.
          """
        },
        %{
          "heading" => "Troubleshooting",
          "body" => [
            "A 404 from the ping means the token is not recognised: check for a truncated secret, or a monitor that was deleted and recreated with a new token.",
            "A 202 with no change in the PostDeploy console means the monitor is paused. Paused monitors accept pings and record nothing, by design.",
            "A skipped or delayed workflow does not create a PostDeploy incident without an inbound failure ping. Use an external watchdog for that condition.",
            "If the workflow stopped running entirely on a public repository, check whether GitHub disabled the schedule for inactivity; the Actions tab shows a banner and a button to re-enable it."
          ]
        }
      ],
      faqs: [
        %{
          "q" => "Why did my scheduled workflow stop running?",
          "a" =>
            "The most common cause on a public repository is GitHub disabling schedules after 60 days without repository activity. The other is queue delay on shared runners, which is worst for schedules on the hour. Neither creates a failed run. Use an external watchdog when that absence needs an alert."
        },
        %{
          "q" => "Should I put the ping in a separate job or the same one?",
          "a" =>
            "The same job, as a final step. A separate job needs an explicit needs: dependency and runs on a fresh runner, which adds a queue wait and another thing that can fail between the work and the report."
        },
        %{
          "q" => "Does this work on a private repository?",
          "a" =>
            "Yes. The 60-day inactivity disabling applies to public repositories, but queue delay and ordinary breakage apply everywhere, and the ping itself is just an outbound HTTPS request from the runner."
        }
      ]
    }
  end

  # -- /guides/kubernetes-cronjob-heartbeat ------------------------------

  defp kubernetes_cronjob_guide do
    %{
      slug: "kubernetes-cronjob-heartbeat",
      path: "/guides/kubernetes-cronjob-heartbeat",
      cluster: "cron",
      intent: :informational,
      primary_query: "kubernetes cronjob not running",
      title: "Monitor a Kubernetes CronJob with a heartbeat | PostDeploy",
      meta_description:
        "Kubernetes skips CronJob runs after 100 missed schedules and silently drops them under Forbid. Report completed and failed runs with a heartbeat ping.",
      nav_label: "Kubernetes CronJob heartbeat",
      summary:
        "The specific ways a Kubernetes CronJob stops running, how to report its completed and failed runs, and when an external watchdog is required.",
      hero_badge: "Guide",
      hero_heading: "Monitor a Kubernetes CronJob",
      hero_description:
        "A Kubernetes CronJob can stop creating Jobs entirely and leave nothing behind to alert on. The controller skips a schedule when the previous run is still going under concurrencyPolicy: Forbid, and stops scheduling altogether after 100 missed start times. PostDeploy records only the heartbeat requests it receives.",
      cta_heading: "Ask a connected MCP client to create this heartbeat",
      cta_label: "Create a heartbeat",
      author_name: @author,
      published_on: @lastmod,
      last_verified_on: @lastmod,
      # SITE-ARCHITECTURE.md §8 publish gate.
      platform: "Kubernetes CronJob",
      docs_host: "kubernetes.io",
      platform_failure_mode:
        "The CronJob controller stops scheduling after 100 missed start times, logging \"too many missed start times\" rather than emitting a Kubernetes Event, and skips a run under concurrencyPolicy: Forbid when the previous run has not finished.",
      sources: [
        %{
          "label" => "CronJob",
          "url" => "https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/",
          "retrieved" => "2026-09-04"
        }
      ],
      not_offered: [
        "PostDeploy does not read Kubernetes cluster state or the controller-manager log",
        "PostDeploy does not restart a failed Job or CronJob",
        "PostDeploy does not monitor pod resource usage or scheduling"
      ],
      code_verified_on: ~D[2026-09-04],
      related_paths: [
        %{"path" => "/docs/monitoring/heartbeats", "label" => "Heartbeat protocol reference"},
        %{"path" => "/monitoring/cron-jobs", "label" => "How cron job monitoring works"},
        %{
          "path" => "/guides/github-actions-heartbeat",
          "label" => "The same problem on GitHub Actions"
        },
        %{"path" => "/monitoring", "label" => "All PostDeploy monitoring"}
      ],
      lastmod: @content_corrected_on,
      body_sections: [
        %{
          "heading" => "How a CronJob stops without telling you",
          "body" => [
            "The Kubernetes documentation is explicit that CronJobs have limitations, and the sharp one is the missed-start-time counter. For each CronJob the controller counts how many schedules were missed since the last scheduled time. If that count passes 100, it stops starting the Job and logs \"too many missed start times\", which is a controller log line, not a Kubernetes Event most alerting will notice.",
            "This is reachable in ordinary operation. With startingDeadlineSeconds unset and a job scheduled every minute, a control plane outage of under two hours is enough to exceed 100 missed schedules and stop the job permanently. Setting startingDeadlineSeconds changes the counting window to that many seconds instead of since the last run, which is why the Kubernetes docs recommend setting it.",
            "The other silent case is concurrencyPolicy: Forbid. A run that outlives its own schedule causes the next start to be skipped and counted as missed. A job that gradually slows down can go from occasionally skipping to never running, and every individual Job that did run succeeded."
          ]
        },
        %{
          "heading" => "A CronJob that reports in",
          "body" => [
            "Put the token in a Secret and reference it as an environment variable. The ping goes at the end of the command, joined with && so it only runs when the work succeeded.",
            "startingDeadlineSeconds is set here deliberately, both because it bounds the missed-schedule counting window and because it keeps a controller restart from replaying a backlog. Keep it above 10 seconds: the controller polls every 10 seconds, and a smaller deadline can cause the job to be missed entirely."
          ],
          "code" => """
          apiVersion: v1
          kind: Secret
          metadata:
            name: alplus-heartbeat
          stringData:
            token: hb_YOUR_TOKEN
          ---
          apiVersion: batch/v1
          kind: CronJob
          metadata:
            name: nightly-report
          spec:
            schedule: "17 3 * * *"
            timeZone: "Etc/UTC"
            # Bounds the missed-schedule window and avoids a catch-up storm.
            startingDeadlineSeconds: 300
            concurrencyPolicy: Forbid
            successfulJobsHistoryLimit: 3
            failedJobsHistoryLimit: 3
            jobTemplate:
              spec:
                template:
                  spec:
                    restartPolicy: OnFailure
                    containers:
                      - name: report
                        image: your-registry/report:1.4.0
                        env:
                          - name: POSTDEPLOY_HEARTBEAT_TOKEN
                            valueFrom:
                              secretKeyRef:
                                name: alplus-heartbeat
                                key: token
                        command: ["/bin/sh", "-c"]
                        args:
                          - >-
                            /app/bin/report &&
                            curl -fsS "#{@ingest}/h/$POSTDEPLOY_HEARTBEAT_TOKEN"
          """
        },
        %{
          "heading" => "Reporting the exit code instead",
          "body" => [
            "The && form stays silent on failure. To alert as soon as a run fails, report the exit code: run the work, capture $?, and send it as a path segment. A 0 is a success and anything else opens an incident immediately.",
            "Note the image needs curl available. If your job image is distroless or scratch, use an available HTTP client or add curl. Use an external watchdog when a missing CronJob run needs an alert."
          ],
          "code" => """
          args:
            - >-
              /app/bin/report; code=$?;
              curl -fsS "#{@ingest}/h/$POSTDEPLOY_HEARTBEAT_TOKEN/$code";
              exit $code
          """
        },
        %{
          "heading" => "Verify it, including the failure path",
          "body" => [
            "Trigger a run immediately rather than waiting for the schedule, then confirm the monitor is passing in PostDeploy."
          ],
          "code" => """
          # Run it now, without waiting for the schedule.
          kubectl create job --from=cronjob/nightly-report nightly-report-manual

          # Watch it, then confirm the ping was sent.
          kubectl logs -f job/nightly-report-manual

          # Check the controller's view of missed schedules.
          kubectl get cronjob nightly-report -o wide

          # If runs stopped, this is the line to look for.
          kubectl -n kube-system logs -l component=kube-controller-manager \\
            | grep -i "too many missed start times"
          """
        },
        %{
          "heading" => "Troubleshooting",
          "body" => [
            "A 404 from the ping means the token is wrong. Confirm the Secret is in the same namespace as the CronJob and that the key name matches secretKeyRef.",
            "If the job runs but the ping never arrives, check egress: a NetworkPolicy or a mesh sidecar that blocks outbound traffic will stop the ping while the work itself succeeds.",
            "If LAST SCHEDULE in kubectl get cronjob is stale, the controller is not creating Jobs. Check for the missed-start-times message, and set startingDeadlineSeconds if it is unset.",
            "If the pings stop only sometimes, look at whether runs are overlapping their own schedule under Forbid. Longer runs skip more starts."
          ]
        }
      ],
      faqs: [
        %{
          "q" => "Why did my CronJob stop creating Jobs?",
          "a" =>
            "Most often the controller exceeded 100 missed start times and stopped scheduling, which it reports in the kube-controller-manager log rather than as an Event. Setting startingDeadlineSeconds changes the counting window to that many seconds and prevents the permanent stop."
        },
        %{
          "q" => "Do I need a sidecar to send the heartbeat?",
          "a" =>
            "No. The ping is one outbound HTTPS request from the job container itself, so a curl call in the command is enough. A sidecar would add a container that has to be reasoned about on every run."
        },
        %{
          "q" => "What should startingDeadlineSeconds be?",
          "a" =>
            "Above 10 seconds, because the controller polls on a 10-second cycle and a smaller value can cause the job to be skipped. Beyond that, set it to how late a run can start and still be worth running."
        },
        %{
          "q" => "My job image has no curl. What are my options?",
          "a" =>
            "Use whatever HTTP client the image already has, since GET and POST are equivalent and no headers are required. Otherwise install curl in the image. A missing run needs an external watchdog."
        }
      ]
    }
  end

  # -- /guides/heroku-scheduler-heartbeat -------------------------------

  defp heroku_scheduler_guide do
    %{
      slug: "heroku-scheduler-heartbeat",
      path: "/guides/heroku-scheduler-heartbeat",
      cluster: "cron",
      intent: :informational,
      primary_query: "heroku scheduler job not running",
      title: "Monitor a Heroku Scheduler job with a heartbeat | PostDeploy",
      meta_description:
        "Heroku Scheduler makes no guarantee that a job runs on time or at all. Report completed and failed jobs with a PostDeploy heartbeat.",
      nav_label: "Heroku Scheduler heartbeat",
      summary:
        "Heroku Scheduler is best effort. Report completed and failed jobs with a heartbeat, and use an external watchdog for skipped or delayed runs.",
      hero_badge: "Guide",
      hero_heading: "Monitor a Heroku Scheduler job",
      hero_description:
        "Heroku Scheduler does not guarantee that a job runs at its scheduled time, or at all. A job can also run twice. Send a heartbeat after the work succeeds to record its completion.",
      cta_heading: "Ask a connected MCP client to create this heartbeat",
      cta_label: "Create a heartbeat",
      author_name: @author,
      published_on: @heartbeat_guide_lastmod,
      last_verified_on: @heartbeat_guide_lastmod,
      platform: "Heroku Scheduler",
      docs_host: "devcenter.heroku.com",
      platform_failure_mode:
        "Heroku Scheduler is best effort. It does not guarantee that jobs run at their scheduled time, or at all, and a job can rarely be skipped or run twice.",
      sources: [
        %{
          "label" => "Heroku Scheduler",
          "url" => "https://devcenter.heroku.com/articles/scheduler",
          "retrieved" => "2026-09-04"
        }
      ],
      not_offered: [
        "PostDeploy does not inspect Heroku Scheduler run history",
        "PostDeploy does not prevent a scheduled job from running twice",
        "PostDeploy does not restart a skipped dyno command"
      ],
      code_verified_on: ~D[2026-09-04],
      related_paths: heartbeat_related_paths("/guides/heroku-scheduler-heartbeat"),
      lastmod: @content_corrected_on,
      body_sections: [
        %{
          "heading" => "The failure this catches",
          "body" => [
            "Heroku calls Scheduler best effort. It gives no guarantee that a command runs at the scheduled time, or at all. Rarely, it can skip a job or run it twice. Neither outcome gives PostDeploy a completed run to poll.",
            "A heartbeat records the signal that arrives. Your command reports only after its useful work succeeds. A skipped or delayed run sends no request, so use an external watchdog when that condition needs an alert. Make the command safe to repeat because a completion heartbeat does not make duplicate work safe."
          ]
        },
        %{
          "heading" => "Add the ping to the command",
          "body" => [
            "Ask a connected MCP client to create the heartbeat. In the Heroku Scheduler command, append the curl command with && so it runs only after the task exits successfully."
          ],
          "code" => "./bin/nightly-report && curl -fsS #{@ingest}/h/hb_YOUR_TOKEN"
        },
        %{
          "heading" => "Report a failure immediately",
          "body" => [
            "Use the exit code form when the task can fail before the next expected heartbeat. It keeps the task exit code unchanged and tells PostDeploy whether the run failed."
          ],
          "code" =>
            "./bin/nightly-report; code=$?; curl -fsS #{@ingest}/h/hb_YOUR_TOKEN/$code; exit $code"
        },
        %{
          "heading" => "Test the monitor",
          "body" => [
            "Run the command once from a one-off dyno or your local shell with the real token. Confirm the monitor records a passing heartbeat. Then force a non-zero exit once and confirm that PostDeploy creates an incident."
          ],
          "code" =>
            "heroku run './bin/nightly-report && curl -fsS #{@ingest}/h/hb_YOUR_TOKEN' --app your-app"
        }
      ],
      faqs: [
        %{
          "q" => "Why did my Heroku Scheduler job not run?",
          "a" =>
            "Heroku Scheduler is best effort. Its documentation says a job has no guarantee of running at its scheduled time, or at all. A fail ping alerts at once. A run that never starts sends nothing, so an interval monitor shows Late on the Monitor screen, with no alert."
        },
        %{
          "q" => "Can Heroku Scheduler run my job twice?",
          "a" =>
            "Yes, rarely. Make the task idempotent. A heartbeat reports that a run completed, but it does not make duplicate work safe."
        }
      ]
    }
  end

  # -- /guides/systemd-timer-heartbeat ----------------------------------

  defp systemd_timer_guide do
    %{
      slug: "systemd-timer-heartbeat",
      path: "/guides/systemd-timer-heartbeat",
      cluster: "cron",
      intent: :informational,
      primary_query: "systemd timer missed run monitoring",
      title: "Monitor a systemd timer with a heartbeat | PostDeploy",
      meta_description:
        "A systemd timer does not replay a missed calendar run by default. Report successful work with a PostDeploy heartbeat.",
      nav_label: "systemd timer heartbeat",
      summary:
        "systemd timers do not replay missed calendar runs by default. Add a heartbeat to record completed work and use an external watchdog for missed runs.",
      hero_badge: "Guide",
      hero_heading: "Monitor a systemd timer",
      hero_description:
        "A systemd timer with Persistent=false does not replay a calendar run missed while the host was down. Report successful work to PostDeploy and use an external watchdog for missed runs.",
      cta_heading: "Ask a connected MCP client to create this heartbeat",
      cta_label: "Create a heartbeat",
      author_name: @author,
      published_on: @heartbeat_guide_lastmod,
      last_verified_on: @heartbeat_guide_lastmod,
      platform: "systemd timers",
      docs_host: "man7.org",
      platform_failure_mode:
        "Persistent= defaults to false. A calendar timer then does not trigger immediately when activated after a run was missed while the host was inactive.",
      sources: [
        %{
          "label" => "systemd.timer",
          "url" => "https://man7.org/linux/man-pages/man5/systemd.timer.5.html",
          "retrieved" => "2026-09-04"
        }
      ],
      not_offered: [
        "PostDeploy does not inspect systemd unit state or the journal",
        "PostDeploy does not start a stopped service unit",
        "PostDeploy does not change Persistent= on a timer"
      ],
      code_verified_on: ~D[2026-09-04],
      related_paths: heartbeat_related_paths("/guides/systemd-timer-heartbeat"),
      lastmod: @content_corrected_on,
      body_sections: [
        %{
          "heading" => "The missed run systemd does not replay",
          "body" => [
            "For a timer with OnCalendar=, Persistent= controls whether systemd catches up after the machine was inactive. It defaults to false. If the host is off at the scheduled time, the timer starts normally later but the missed work does not run.",
            "Set Persistent=true when catch-up work is correct for the task. Keep a heartbeat even then. It records that the service completed rather than only that the timer became active. Use an external watchdog if an absent completion needs an alert."
          ]
        },
        %{
          "heading" => "Create the timer and service",
          "body" => [
            "Put the work and heartbeat in a oneshot service. The shell uses && so a success ping follows successful work only. Enable the timer, not the service."
          ],
          "code" => """
          # /etc/systemd/system/nightly-report.service
          [Service]
          Type=oneshot
          ExecStart=/bin/sh -c '/opt/report/bin/run && curl -fsS #{@ingest}/h/hb_YOUR_TOKEN'

          # /etc/systemd/system/nightly-report.timer
          [Timer]
          OnCalendar=*-*-* 03:17:00
          Persistent=true

          [Install]
          WantedBy=timers.target
          """
        },
        %{
          "heading" => "Enable and verify it",
          "body" => [
            "Reload systemd after writing both unit files. Start the timer, then start the service once by hand. Confirm the heartbeat arrives before you rely on the next calendar time."
          ],
          "code" => """
          sudo systemctl daemon-reload
          sudo systemctl enable --now nightly-report.timer
          sudo systemctl start nightly-report.service
          systemctl list-timers nightly-report.timer
          """
        },
        %{
          "heading" => "Find a missed run",
          "body" => [
            "If the heartbeat is late, check the timer's next and last trigger time, then inspect the service journal. A timer that never triggered after a host outage likely had Persistent=false when it missed the calendar time."
          ],
          "code" =>
            "systemctl status nightly-report.timer && journalctl -u nightly-report.service --since yesterday"
        }
      ],
      faqs: [
        %{
          "q" => "Does systemd replay a missed timer by default?",
          "a" =>
            "No. Persistent= defaults to false. For calendar timers, a missed run while the system was inactive is not replayed when the timer activates."
        },
        %{
          "q" => "Should I set Persistent=true?",
          "a" =>
            "Set it when one catch-up run is safe and useful. Do not use it for work where late execution can damage data or create an unwanted backlog."
        }
      ]
    }
  end

  # -- /guides/laravel-scheduler-heartbeat ------------------------------

  defp laravel_scheduler_guide do
    %{
      slug: "laravel-scheduler-heartbeat",
      path: "/guides/laravel-scheduler-heartbeat",
      cluster: "cron",
      intent: :informational,
      primary_query: "laravel scheduler withoutoverlapping stuck lock",
      title: "Monitor Laravel Scheduler with a heartbeat | PostDeploy",
      meta_description:
        "Laravel withoutOverlapping locks expire after 24 hours by default and can survive an unexpected server problem. Report completed and failed tasks with a heartbeat.",
      nav_label: "Laravel Scheduler heartbeat",
      summary:
        "A Laravel withoutOverlapping lock lasts 24 hours by default and can block a task after a server problem. Add a heartbeat after successful work.",
      hero_badge: "Guide",
      hero_heading: "Monitor Laravel Scheduler",
      hero_description:
        "Laravel Scheduler prevents overlap with a cache lock. The lock expires after 24 hours by default and can need manual clearing after an unexpected server problem. A heartbeat records tasks that complete.",
      cta_heading: "Ask a connected MCP client to create this heartbeat",
      cta_label: "Create a heartbeat",
      author_name: @author,
      published_on: @heartbeat_guide_lastmod,
      last_verified_on: @heartbeat_guide_lastmod,
      platform: "Laravel Scheduler",
      docs_host: "laravel.com",
      platform_failure_mode:
        "The withoutOverlapping lock expires after 24 hours by default. An unexpected server problem can leave a task stuck until the lock expires or schedule:clear-cache clears it.",
      sources: [
        %{
          "label" => "Task Scheduling: Preventing Task Overlaps",
          "url" => "https://laravel.com/docs/12.x/scheduling#preventing-task-overlaps",
          "retrieved" => "2026-09-04"
        }
      ],
      not_offered: [
        "PostDeploy does not read Laravel cache locks",
        "PostDeploy does not run schedule:clear-cache",
        "PostDeploy does not execute Artisan commands on your server"
      ],
      code_verified_on: ~D[2026-09-04],
      related_paths: heartbeat_related_paths("/guides/laravel-scheduler-heartbeat"),
      lastmod: @content_corrected_on,
      body_sections: [
        %{
          "heading" => "The lock that blocks tomorrow's task",
          "body" => [
            "withoutOverlapping prevents two copies of the same task from running at once. Its cache lock expires after 24 hours by default. Laravel documents that an unexpected server problem can leave the lock stuck, requiring schedule:clear-cache.",
            "Shorten the lock only when you know the maximum safe run time. Then send a heartbeat after the task finishes. The heartbeat records completion. Use an external watchdog when a stuck lock or other absent task needs an alert."
          ]
        },
        %{
          "heading" => "Add a success heartbeat",
          "body" => [
            "Use onSuccess() to report only after the scheduled command succeeds. Keep the heartbeat URL in an environment variable, not in source control. The example limits the lock to 30 minutes because the task should normally finish well inside that time."
          ],
          "code" => """
          # .env
          POSTDEPLOY_HEARTBEAT_URL=#{@ingest}/h/hb_YOUR_TOKEN

          use Illuminate\\Support\\Facades\\Schedule;
          use Illuminate\\Support\\Facades\\Http;

          Schedule::command('reports:nightly')
              ->dailyAt('03:17')
              ->withoutOverlapping(30)
              ->onSuccess(function () {
                  Http::get(config('services.postdeploy.heartbeat_url'));
              });
          """
        },
        %{
          "heading" => "Test the scheduler and recovery",
          "body" => [
            "Run the scheduler manually and confirm a passing heartbeat. If a task stops running after a server problem, inspect its cache backend and clear only the Scheduler locks after you understand the impact."
          ],
          "code" => """
          php artisan schedule:run
          php artisan schedule:list
          php artisan schedule:clear-cache
          """
        },
        %{
          "heading" => "Alert on a failed task sooner",
          "body" => [
            "A missing success heartbeat does not currently create a PostDeploy incident. Add Laravel failure handling and an explicit non-zero heartbeat ping when you need immediate failure detection. Use an external watchdog for a task that did not start at all."
          ]
        }
      ],
      faqs: [
        %{
          "q" => "How long does Laravel withoutOverlapping lock a task?",
          "a" =>
            "It expires after 24 hours by default. Pass a minute value to withoutOverlapping when you know a shorter timeout is safe."
        },
        %{
          "q" => "How do I clear a stuck Laravel schedule lock?",
          "a" =>
            "Laravel provides php artisan schedule:clear-cache. Use it when an unexpected server problem left a Scheduler lock stuck, after checking that another task instance is not still running."
        }
      ]
    }
  end

  # -- /guides/airflow-heartbeat ----------------------------------------

  defp airflow_guide do
    %{
      slug: "airflow-heartbeat",
      path: "/guides/airflow-heartbeat",
      cluster: "cron",
      intent: :informational,
      primary_query: "airflow dag paused not running",
      title: "Monitor an Apache Airflow DAG with a heartbeat | PostDeploy",
      meta_description:
        "A paused Apache Airflow DAG creates no scheduled runs. Send a PostDeploy heartbeat after the final task succeeds to record completion.",
      nav_label: "Apache Airflow heartbeat",
      summary:
        "A paused Apache Airflow DAG does not schedule runs. Report successful DAG completion with a heartbeat and use an external watchdog for missing runs.",
      hero_badge: "Guide",
      hero_heading: "Monitor an Apache Airflow DAG",
      hero_description:
        "A paused DAG is not scheduled by Airflow. Manual triggers still work, which can hide the problem during an investigation. A heartbeat after the final task records a completed run.",
      cta_heading: "Ask a connected MCP client to create this heartbeat",
      cta_label: "Create a heartbeat",
      author_name: @author,
      published_on: @heartbeat_guide_lastmod,
      last_verified_on: @heartbeat_guide_lastmod,
      platform: "Apache Airflow",
      docs_host: "airflow.apache.org",
      platform_failure_mode:
        "A paused DAG is not scheduled by the Airflow Scheduler, although it can still be triggered manually through the UI.",
      sources: [
        %{
          "label" => "Apache Airflow DAGs: DAG pausing, deactivation and deletion",
          "url" =>
            "https://airflow.apache.org/docs/apache-airflow/stable/core-concepts/dags.html",
          "retrieved" => "2026-09-04"
        }
      ],
      not_offered: [
        "PostDeploy does not read Airflow task logs or scheduler logs",
        "PostDeploy does not unpause a DAG",
        "PostDeploy does not trigger or retry an Airflow DAG run"
      ],
      code_verified_on: ~D[2026-09-04],
      related_paths: heartbeat_related_paths("/guides/airflow-heartbeat"),
      lastmod: @content_corrected_on,
      body_sections: [
        %{
          "heading" => "The scheduled run that never exists",
          "body" => [
            "Airflow does not schedule a paused DAG. You can still trigger the DAG manually in the UI, so one successful manual run does not prove the timetable is active. The scheduler can produce no scheduled run and no task failure for your normal alerting to read.",
            "Place a heartbeat task after the work you care about. It sends only when upstream tasks succeed. When the DAG is paused or never reaches its final task, PostDeploy receives no ping. Use an external watchdog when that absence needs an alert."
          ]
        },
        %{
          "heading" => "Add a final heartbeat task",
          "body" => [
            "Store the full heartbeat URL in an Airflow Connection, Variable or secret backend. This example uses a Variable to keep the DAG file free of the token."
          ],
          "code" => """
          airflow variables set postdeploy_heartbeat_url '#{@ingest}/h/hb_YOUR_TOKEN'

          from airflow.models import Variable
          from airflow.operators.bash import BashOperator
          from airflow.sdk import DAG
          from pendulum import datetime

          with DAG(
              dag_id="nightly_report",
              schedule="17 3 * * *",
              start_date=datetime(2026, 1, 1, tz="UTC"),
              catchup=False,
          ) as dag:
              report = BashOperator(task_id="report", bash_command="/opt/report/bin/run")
              heartbeat = BashOperator(
                  task_id="postdeploy_heartbeat",
                  bash_command=f"curl -fsS {Variable.get('postdeploy_heartbeat_url')}",
              )
              report >> heartbeat
          """
        },
        %{
          "heading" => "Verify scheduled execution",
          "body" => [
            "Check that the DAG is unpaused and has a next run. Trigger one manual run to verify the token and network path, then wait for or observe one scheduled run. These are separate checks because a paused DAG can still accept a manual trigger."
          ],
          "code" => """
          airflow dags unpause nightly_report
          airflow dags list-runs -d nightly_report
          airflow dags trigger nightly_report
          """
        },
        %{
          "heading" => "Troubleshoot a late heartbeat",
          "body" => [
            "First check whether the DAG is paused. Then check the DAG run and its upstream tasks. If a manual run works but scheduled runs do not appear, investigate the scheduler and timetable rather than the heartbeat task."
          ]
        }
      ],
      faqs: [
        %{
          "q" => "Does a paused Airflow DAG still run on its schedule?",
          "a" =>
            "No. Airflow does not schedule a paused DAG. You can still trigger it manually, which is why a manual success does not prove scheduled execution works."
        },
        %{
          "q" => "Where should the heartbeat task go in an Airflow DAG?",
          "a" =>
            "Put it after the task or task group that represents successful completion. It records a completed run when required upstream work succeeds. Use an external watchdog for absent work."
        }
      ]
    }
  end

  # -- /guides/gitlab-ci-schedule-heartbeat -----------------------------

  defp gitlab_ci_schedule_guide do
    %{
      slug: "gitlab-ci-schedule-heartbeat",
      path: "/guides/gitlab-ci-schedule-heartbeat",
      cluster: "cron",
      intent: :informational,
      primary_query: "gitlab ci schedule inactive owner blocked",
      title: "Monitor a GitLab CI schedule with a heartbeat | PostDeploy",
      meta_description:
        "GitLab CI schedules become inactive when their owner is blocked or removed. Add a PostDeploy heartbeat to record completed pipelines.",
      nav_label: "GitLab CI schedule heartbeat",
      summary:
        "GitLab scheduled pipelines run as their owner and can become inactive when that user is blocked or removed. Add a heartbeat after the job succeeds.",
      hero_badge: "Guide",
      hero_heading: "Monitor a GitLab CI schedule",
      hero_description:
        "GitLab runs a scheduled pipeline with its owner's permissions. If that owner is blocked or removed from the project, the schedule can become inactive and stop running. A final heartbeat reports the pipeline that completed.",
      cta_heading: "Ask a connected MCP client to create this heartbeat",
      cta_label: "Create a heartbeat",
      author_name: @author,
      published_on: @heartbeat_guide_lastmod,
      last_verified_on: @heartbeat_guide_lastmod,
      platform: "GitLab CI schedules",
      docs_host: "docs.gitlab.com",
      platform_failure_mode:
        "Scheduled pipelines run with the schedule owner's permissions. A schedule can become Inactive when its owner is blocked or removed from the project.",
      sources: [
        %{
          "label" => "GitLab CI/CD pipeline schedules",
          "url" => "https://docs.gitlab.com/ci/pipelines/schedules/",
          "retrieved" => "2026-09-04"
        }
      ],
      not_offered: [
        "PostDeploy does not read GitLab pipeline logs",
        "PostDeploy does not change a schedule owner or reactivate a schedule",
        "PostDeploy does not trigger a GitLab pipeline"
      ],
      code_verified_on: ~D[2026-09-04],
      related_paths: heartbeat_related_paths("/guides/gitlab-ci-schedule-heartbeat"),
      lastmod: @content_corrected_on,
      body_sections: [
        %{
          "heading" => "The owner who stops the schedule",
          "body" => [
            "GitLab runs scheduled pipelines with the permissions of the schedule owner. If that person is blocked or removed from the project, the schedule can change to Inactive and stop creating pipelines. GitLab also stops scheduled pipelines when the project or group is marked for deletion.",
            "A heartbeat cannot repair the schedule. It records a completed pipeline. Use an external watchdog when a missing pipeline needs an alert for someone who can change the owner or reactivate the schedule."
          ]
        },
        %{
          "heading" => "Add a final CI job",
          "body" => [
            "Save the PostDeploy token as a masked CI/CD variable named POSTDEPLOY_HEARTBEAT_TOKEN. Put the heartbeat job in the final stage and require the scheduled work to finish first."
          ],
          "code" => """
          stages:
            - report
            - monitor

          nightly_report:
            stage: report
            script:
              - ./bin/nightly-report

          postdeploy_heartbeat:
            stage: monitor
            needs: [nightly_report]
            script:
              - curl -fsS "#{@ingest}/h/$POSTDEPLOY_HEARTBEAT_TOKEN"
            rules:
              - if: '$CI_PIPELINE_SOURCE == "schedule"'
          """
        },
        %{
          "heading" => "Check the schedule owner",
          "body" => [
            "Open Build, Pipeline schedules and confirm the schedule is Active and has the intended owner. Run it once manually to confirm the heartbeat, then check the next scheduled pipeline appears. Use a service account or a stable maintainer account where your GitLab policy permits it."
          ]
        },
        %{
          "heading" => "Respond to a missing pipeline",
          "body" => [
            "When an external watchdog reports a missing pipeline, first inspect the schedule status and owner. If a pipeline exists but the heartbeat job did not run, inspect the job graph and rules."
          ]
        }
      ],
      faqs: [
        %{
          "q" => "Why did my GitLab pipeline schedule become inactive?",
          "a" =>
            "A schedule can become Inactive when its owner is blocked or removed from the project. Scheduled pipelines also stop when GitLab marks the project or group for deletion."
        },
        %{
          "q" => "Which permissions does a GitLab scheduled pipeline use?",
          "a" =>
            "It runs with the permissions of the user who owns the schedule. Review that owner when a scheduled pipeline changes behaviour after membership changes."
        }
      ]
    }
  end

  defp heartbeat_related_paths(current_path) do
    [
      %{"path" => "/docs/monitoring/heartbeats", "label" => "Heartbeat protocol reference"},
      %{"path" => "/monitoring/cron-jobs", "label" => "How cron job monitoring works"},
      %{
        "path" => "/guides/github-actions-heartbeat",
        "label" => "Monitor a GitHub Actions schedule"
      },
      %{
        "path" => "/guides/kubernetes-cronjob-heartbeat",
        "label" => "Monitor a Kubernetes CronJob"
      },
      %{"path" => "/monitoring", "label" => "All PostDeploy monitoring"}
    ]
    |> Enum.reject(&(&1["path"] == current_path))
  end
end
