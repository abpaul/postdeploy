defmodule Alplus.Content.EditorialSeeds do
  @moduledoc "Seeds the dated technical guides that extend the public pillars."

  alias Alplus.Content

  @prepared_on ~D[2026-09-09]
  @author "Paul"

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

  defp guides,
    do: [backup_heartbeat(), analytics_disagreement(), release_errors(), certificate_expiry()]

  defp backup_heartbeat do
    %{
      slug: "backup-heartbeat",
      path: "/guides/backup-heartbeat",
      cluster: "cron",
      intent: :informational,
      primary_query: "how to monitor scheduled backups",
      title: "How to monitor a scheduled backup with a completion heartbeat | PostDeploy",
      meta_description:
        "An HTTP check can show that your application is online while a scheduled backup has not run. Send a completion heartbeat after the backup command succeeds.",
      nav_label: "Backup heartbeat",
      summary:
        "An HTTP check cannot prove a scheduled backup ran. Report completion from the backup job, then monitor explicit failure separately.",
      hero_badge: "Guide",
      hero_heading: "Know that the backup ran",
      hero_description:
        "A healthy web endpoint does not prove a scheduled backup completed. Send a heartbeat after the final required backup step so an explicit failure becomes visible.",
      author_name: @author,
      last_verified_on: @prepared_on,
      code_verified_on: @prepared_on,
      lastmod: @prepared_on,
      status: "published",
      related_guide_path: "/guides/systemd-timer-heartbeat",
      related_paths: [
        %{"path" => "/monitoring/cron-jobs", "label" => "How cron job monitoring works"},
        %{"path" => "/monitoring/uptime", "label" => "How HTTP uptime checks work"},
        %{"path" => "/guides/systemd-timer-heartbeat", "label" => "Monitor a systemd timer"},
        %{
          "path" => "/guides/kubernetes-cronjob-heartbeat",
          "label" => "Monitor a Kubernetes CronJob"
        }
      ],
      cta_heading: "Ask a connected MCP client to create this heartbeat",
      cta_label: "Start your 14-day free trial",
      not_offered: [
        "PostDeploy does not perform backup restore testing.",
        "PostDeploy does not inspect backup contents or retention.",
        "PostDeploy does not upload, encrypt, or store backups."
      ],
      sources: [
        %{
          "label" => "PostgreSQL 18: pg_dump",
          "url" => "https://www.postgresql.org/docs/18/app-pgdump.html",
          "retrieved" => "2026-09-09"
        },
        %{
          "label" => "PostgreSQL 18: SQL dump and restore",
          "url" => "https://www.postgresql.org/docs/18/backup-dump.html",
          "retrieved" => "2026-09-09"
        },
        %{
          "label" => "curl FAQ: HTTP errors and --fail",
          "url" => "https://curl.se/docs/faq.html",
          "retrieved" => "2026-09-09"
        }
      ],
      body_sections: [
        %{
          "heading" => "A successful HTTP check does not prove your backup ran",
          "body" => [
            "Your status endpoint can return 200 while a separate scheduled backup has not run. An HTTP uptime monitor answers one narrow question: can a client reach this endpoint and receive the expected response now? It says nothing about a scheduled process that creates, uploads, or retains a backup.",
            "This gap appears when a scheduler stops, the backup command loses database access, a changed environment variable points at the wrong destination, or an upload fails after the dump completes. A green HTTP check and a missing backup can exist at the same time because they observe different work.",
            "Put the heartbeat in the same process that runs the backup. A separate cron entry can run successfully even when the backup never starts. PostDeploy records a non-zero exit code as an explicit failed heartbeat. PostDeploy does not currently create a missed-run incident when no finish heartbeat arrives. Use an independent scheduler watchdog if you need that alert."
          ]
        },
        %{
          "heading" => "Report the backup command result",
          "body" => [
            "If your PostgreSQL job uses `pg_dump`, its custom archive format restores with `pg_restore`. The command below shows the reporting order. It does not prescribe a production backup design.",
            "Set `POSTDEPLOY_INGEST_URL` to `https://ingest.postdeploy.dev` and store the token where the scheduler can read it. The token is a credential. Do not put it in source control or print it in logs.",
            "The `/0` path records a successful finish. A non-zero final path segment records a failed run. The wrapper preserves a failed backup exit status. When the backup succeeds but delivery fails, it exits with the curl status so the scheduler records the delivery failure. `curl -f` makes a 4xx or 5xx response fail the transfer."
          ],
          "code" => """
          #!/bin/sh
          set -u

          backup_file=\"/var/backups/app-$(date +%F).dump\"

          pg_dump --format=custom --file \"$backup_file\" \"$PGDATABASE\"
          backup_status=$?

          curl -fsS --max-time 10 \\
            \"$POSTDEPLOY_INGEST_URL/h/$POSTDEPLOY_HEARTBEAT_TOKEN/$backup_status\"
          delivery_status=$?

          if [ \"$backup_status\" -ne 0 ]; then
            exit \"$backup_status\"
          fi

          exit \"$delivery_status\"
          """
        },
        %{
          "heading" => "Put the success ping after the final required step",
          "body" => [
            "A successful dump file may still not be a usable backup if a later upload or encryption step fails. Send the success heartbeat after the last step that makes the backup available where you rely on it.",
            "Warning: `upload_backup` and `verify_backup_object` below are placeholders. Replace them with commands that your backup system provides before you run this pattern. Do not place a success ping before the upload. Do not write `backup_command; curl ...` without preserving the exit status."
          ],
          "code" => """
          # Replace upload_backup and verify_backup_object with your own commands.
          pg_dump --format=custom --file /tmp/app.dump \"$PGDATABASE\" &&
          upload_backup /tmp/app.dump \"backups/app-$(date +%F).dump\" &&
          verify_backup_object \"backups/app-$(date +%F).dump\"
          backup_status=$?

          curl -fsS --max-time 10 \\
            \"$POSTDEPLOY_INGEST_URL/h/$POSTDEPLOY_HEARTBEAT_TOKEN/$backup_status\"
          delivery_status=$?

          if [ \"$backup_status\" -ne 0 ]; then
            exit \"$backup_status\"
          fi

          exit \"$delivery_status\"
          """
        },
        %{
          "heading" => "A completed backup is not a recovery or missed-run test",
          "body" => [
            "A success heartbeat shows that the job reached the reporting line and the endpoint accepted that report. It cannot show that the backup still exists, has the expected contents, meets retention rules, or can restore your application.",
            "PostDeploy has no independent deadline evaluator for a missing finish. A stopped scheduler, an absent first run, or a command that never reaches the reporting line creates no check or incident. Use an external scheduler watchdog where you need missed-run detection.",
            "Run a restore test on a separate schedule and give it its own heartbeat. PostgreSQL documents `pg_restore` as the tool to rebuild a custom-format archive. The backup job and restore test should have separate evidence because a recent dump is not evidence of a successful recovery."
          ]
        },
        %{
          "heading" => "Test the reporting paths before relying on them",
          "body" => [
            "Run the real backup once and confirm that the completion report appears as a passing check. Then force a harmless failure in a non-production test and confirm that a non-zero exit creates the failed check you expect. Do not claim that stopping the scheduler creates a PostDeploy alert. These checks do not prove recovery until the restore test succeeds.",
            "Keep the HTTP uptime monitor too. It protects the user-facing endpoint. Add the completion heartbeat because the backup is a different failure domain."
          ]
        }
      ],
      faqs: [
        %{
          "q" => "Does an HTTP uptime check prove my backup ran?",
          "a" =>
            "No. It proves that the monitored endpoint responded. A heartbeat sent after the backup completes reports a different job."
        },
        %{
          "q" => "Should I send the heartbeat before or after upload?",
          "a" =>
            "Send it after the last required step. A dump that was never stored where you need it is not a successful backup."
        },
        %{
          "q" => "Does a successful heartbeat prove I can restore?",
          "a" => "No. Run a restore test separately and give it its own heartbeat."
        }
      ]
    }
  end

  defp analytics_disagreement do
    %{
      slug: "why-analytics-tools-disagree",
      path: "/guides/why-analytics-tools-disagree",
      cluster: "measure",
      intent: :informational,
      primary_query: "why analytics tools disagree",
      title: "Why analytics tools disagree about visitors | PostDeploy",
      meta_description:
        "Analytics tools can report different visitor totals without either tool being broken. Learn which definitions, identifiers, sessions, and referrals change the count.",
      nav_label: "Analytics totals",
      summary:
        "Visitor totals can differ because tools use different definitions, identifiers, sessions, collection paths, and time zones.",
      hero_badge: "Guide",
      hero_heading: "Why analytics tools disagree about visitors",
      hero_description:
        "Compare metric definitions, identifiers, collection, and time zones before you decide that a visitor total is wrong.",
      author_name: @author,
      last_verified_on: @prepared_on,
      lastmod: @prepared_on,
      status: "published",
      related_paths: [
        %{"path" => "/analytics", "label" => "PostDeploy analytics"},
        %{"path" => "/privacy", "label" => "PostDeploy privacy"},
        %{
          "path" => "/alternatives/google-analytics",
          "label" => "PostDeploy compared with Google Analytics"
        }
      ],
      cta_heading: "Ask a connected MCP client to add Measure to this project",
      cta_label: "View PostDeploy analytics",
      not_offered: [
        "Measure does not report returning visitors across days.",
        "Measure does not provide goal conversion reporting.",
        "Measure does not retain raw IP addresses, raw user agents, or raw hits."
      ],
      sources: [
        %{
          "label" => "Google: Understand user metrics",
          "url" => "https://support.google.com/analytics/answer/12253918?hl=en",
          "retrieved" => "2026-09-09"
        },
        %{
          "label" => "Google: User Explorer",
          "url" => "https://support.google.com/analytics/answer/9283607?hl=en",
          "retrieved" => "2026-09-09"
        },
        %{
          "label" => "Plausible: Metrics definitions",
          "url" => "https://plausible.io/docs/metrics-definitions",
          "retrieved" => "2026-09-09"
        },
        %{
          "label" => "MDN: Document referrer",
          "url" => "https://developer.mozilla.org/en-US/docs/Web/API/Document/referrer",
          "retrieved" => "2026-09-09"
        },
        %{
          "label" => "MDN: Referrer-Policy",
          "url" =>
            "https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Referrer-Policy",
          "retrieved" => "2026-09-09"
        }
      ],
      body_sections: [
        %{
          "heading" => "Start with the metric name",
          "body" => [
            "Two analytics dashboards can observe the same site on the same day and show different visitor totals. That result does not prove that one dashboard is wrong. The number depends on what each tool counts, when it resets its identifier, which requests it receives, and how it groups activity.",
            "Visitors is not a universal unit. A tool can use the word for a daily browser estimate, a person known across several visits, or a user who meets an engagement rule. Google Analytics 4 defines total users as unique users who triggered an event in the selected date range. Its returning-user reporting needs an identifier that links activity across sessions. See the Google sources below.",
            "Plausible documents a different contract. Its unique visitors are unique within the same day. A person who returns on another day, or uses another device, counts again. Its sessions begin on arrival and end after 30 minutes without action. Neither choice makes a better visitor number in every context. They answer different questions."
          ]
        },
        %{
          "heading" => "What Measure counts",
          "body" => [
            "Measure records pageviews and registered custom events. A pageview becomes one pageview when the tracker sends it. Page reloads and client-side navigation can create more pageviews. The tracker sends the page path without the query string or fragment, so a campaign parameter does not create a separate page path.",
            "For a Measure pageview, the server creates a keyed hash from the project, source, remote IP address, user agent, and that day's secret salt. It stores the hash only as needed to prevent a second count during that UTC day. It does not store the raw IP address, raw user agent, raw hit, or a persistent visitor identifier.",
            "The salt changes each day. Measure cannot join those daily hashes. It cannot report how many people returned next week, a lifetime visitor count, or a returning-user rate. Read a Measure visitor total as distinct daily hash inputs that sent accepted pageviews. Do not translate it to known people."
          ]
        },
        %{
          "heading" => "Visits and visitors answer different questions",
          "body" => [
            "Measure starts a visit with a pageview and begins another visit after more than 30 minutes without activity. It keeps this visit state in memory. A second pageview inside that window adds a pageview but does not start another visit. A later pageview starts a new visit.",
            "One daily visitor can have several visits. A person can also count as more than one visitor when the hash inputs differ. Conversely, several people can produce the same inputs. Read visits as grouped activity, pageviews as loads, and visitors as a daily estimate. Do not use one as a substitute for another.",
            "Compare like with like. If another dashboard uses a 30-minute session, compare Measure visits with that dashboard's sessions. If it uses a persistent identity, do not expect its users or returning users to match Measure visitors."
          ]
        },
        %{
          "heading" => "Why the totals can still differ",
          "body" => [
            "Definitions are only the first difference. The Measure script sends a pageview from the visitor's browser to the Measure endpoint. A blocked script, a browser setting, a network failure, or a page that does not load the script leaves no Measure pageview. Another tool can collect a request that Measure did not see, or miss a request that Measure saw.",
            "Time zones also change daily buckets. Measure's daily visitor salt and day rollups use UTC. A dashboard that labels days in a local time zone can place activity near midnight in a different day. Compare a full date range before you investigate one unusual day.",
            "Scope matters too. Measure ties a source to one site. If another report combines a production domain, preview domain, and documentation domain, it can show a larger total. Compare the same hostnames, date range, environment, and traffic filters."
          ]
        },
        %{
          "heading" => "Read referral data as a clue",
          "body" => [
            "Measure reads the browser's `document.referrer`, reduces it to the referring host, and stores that host in its rollup. It records `direct` when the browser supplies no referrer or when the referrer is one of the site's own allowed domains. It does not keep the referrer path, query string, or fragment.",
            "A `direct` total does not prove that every visitor typed the address. It means Measure did not receive an external referring host for those pageviews. A bookmark can produce an empty referrer. A site or browser can also apply a referrer policy that omits referrer information. See the MDN sources below.",
            "Match the hostname, source, date range, and time zone. Compare pageviews first. Then compare sessions, identifiers, reset periods, and blocked or filtered collection. A difference can show which behavior the tools measure differently. Do not average the totals."
          ]
        }
      ],
      faqs: [
        %{
          "q" => "Why can two analytics tools show different visitors?",
          "a" =>
            "They can use different identifiers, reset periods, session rules, time zones, hostnames, and collection paths."
        },
        %{
          "q" => "Can Measure report returning visitors?",
          "a" =>
            "No. Measure rotates the salt that derives its visitor hash each UTC day and cannot join the hashes across days."
        },
        %{
          "q" => "Does direct traffic mean a visitor typed the address?",
          "a" => "No. It means Measure received no external referring host for the pageview."
        }
      ]
    }
  end

  defp release_errors do
    %{
      slug: "investigate-errors-after-release",
      path: "/guides/investigate-errors-after-release",
      cluster: "observe",
      intent: :informational,
      primary_query: "investigate errors after a release",
      title: "Investigate errors after a release: find evidence before cause | PostDeploy",
      meta_description:
        "Use release labels, error groups, stack traces, and a repeatable test to investigate a post-release error without confusing timing with cause.",
      nav_label: "Investigate release errors",
      summary:
        "Use release labels, grouped errors, stack traces, and a narrow test to investigate a release without treating timing as proof of cause.",
      hero_badge: "Guide",
      hero_heading: "Investigate errors after a release without guessing",
      hero_description:
        "A release can coincide with an error spike without causing it. Use the release as a time marker, then test one narrow explanation against grouped error evidence.",
      author_name: @author,
      last_verified_on: @prepared_on,
      lastmod: @prepared_on,
      status: "published",
      related_paths: [
        %{"path" => "/error-tracking", "label" => "Error tracking with PostDeploy Observe"},
        %{"path" => "/monitoring/uptime", "label" => "Uptime monitoring for the same project"},
        %{"path" => "/analytics", "label" => "Cookieless web analytics with PostDeploy Measure"},
        %{"path" => "/changelog", "label" => "PostDeploy changelog"}
      ],
      cta_heading: "Ask a connected MCP client to configure Observe for this project",
      cta_label: "View error tracking",
      not_offered: [
        "Observe does not ingest logs.",
        "Observe does not collect traces, metrics, or session replay.",
        "A recorded release label does not prove that the release caused an error."
      ],
      sources: [
        %{
          "label" => "Git bisect documentation",
          "url" => "https://git-scm.com/docs/git-bisect",
          "retrieved" => "2026-09-09"
        },
        %{
          "label" => "ECMA-426 Source map format specification",
          "url" => "https://tc39.es/ecma426/",
          "retrieved" => "2026-09-09"
        }
      ],
      body_sections: [
        %{
          "heading" => "Confirm that the error is one problem",
          "body" => [
            "A release and an error spike can happen at the same time for different reasons. The release may contain the defect. A feature flag may have changed. A dependency may have failed. More traffic may have reached an existing fault. Treat the release as a useful time marker, not a verdict.",
            "Start with the grouped issue, not the raw event list. A group gives you the exception type, message, stack frames, first seen time, last seen time, and event count. Check the first seen time against the release time. Then check the release label on the first and latest events.",
            "A useful candidate regression has three facts: the issue was absent before the release, it first appeared after the release reached users, and new events carry the expected release label and environment. If an issue appeared before the release, the release did not introduce it. It may still have increased the event rate."
          ]
        },
        %{
          "heading" => "Check whether the sample can support the comparison",
          "body" => [
            "An event count alone does not show impact. Compare equal periods before and after the release. Keep the source and environment the same. Check error events first. Then check Monitor results and Measure traffic for the same period, if you use those tools.",
            "Ask whether errors increased after the release, whether traffic changed by a similar amount, and whether an uptime incident overlapped the release window. Error growth with stable traffic supports a product regression. Error growth with matching traffic may show an existing fault that reached more users. An overlapping upstream outage can explain both errors and failed checks.",
            "Observe groups errors. Monitor records checks and incidents. Measure records aggregate traffic. Each signal can support a diagnosis, but none proves one by itself. Warning: do not compare an incomplete after period with a full before period."
          ]
        },
        %{
          "heading" => "Read the stack trace where the program failed",
          "body" => [
            "Open a recent occurrence in the issue. Read the exception type and message. Then find the first stack frame from your application code. That frame is usually the best place to begin.",
            "A JavaScript production stack can name a generated file and compressed line number. Upload the source map for the same release before matching errors arrive. Symbolication happens during event ingest, not retroactively. Name the artifact with the generated bundle basename plus `.map`, such as `app-abc123.js.map` for `app-abc123.js`. A different filename leaves the frame unchanged. The ECMA-426 source map specification describes the mapping from generated positions to source representation.",
            "Read request data, tags, breadcrumbs, and the full payload only when they answer the current question. Write one testable hypothesis, such as a missing account value passed to checkout when a flag is enabled. A testable sentence is better than saying that the release broke checkout."
          ]
        },
        %{
          "heading" => "Reproduce the smallest failing case",
          "body" => [
            "Use the stack frame, error message, and event context to create one focused check. Run it against the release code or a safe local copy. Keep the test close to the failing input.",
            "Mark the result clearly. Reproduced means the check fails with the reported condition. Not reproduced means the current evidence does not support the hypothesis. Cannot test means a required dependency or production state is missing. Do not call a release the cause when the test cannot reproduce the fault.",
            "When you have a known good release and a known bad release, Git can reduce the commit range. Git bisect uses binary search between those endpoints. Use it only with a reliable test. An unstable test can produce a false first bad commit."
          ]
        },
        %{
          "heading" => "Fix, verify, and close the loop",
          "body" => [
            "Deploy the fix with a new release label. Inspect the existing issue in the PostDeploy console. Confirm that new occurrences stop or decline in the new release window.",
            "Resolve the issue through a connected MCP client only after the evidence supports the fix. A new matching event automatically reopens a resolved or ignored issue and marks a regression. Compare that new occurrence with the original hypothesis.",
            "Record the final cause through the issue comment action in a connected MCP client. Include the triggering condition, the change that fixed it, and the verification you ran. Observe records grouped errors, release labels, stack traces, release artifacts, and aggregate crash-free session data. It does not ingest logs, collect traces, compute application metrics, or record session replay."
          ]
        }
      ],
      faqs: [
        %{
          "q" => "Does a release label prove the release caused an error?",
          "a" =>
            "No. It provides timing and context. Reproduce a narrow hypothesis before you assign cause."
        },
        %{
          "q" => "What should I compare with an error spike?",
          "a" =>
            "Compare equal time windows, the same source and environment, traffic, and overlapping uptime incidents."
        },
        %{
          "q" => "Can Observe replace logs or tracing?",
          "a" =>
            "No. Observe records errors and release context. Use logs or tracing when the captured error context cannot explain a dependency failure."
        }
      ]
    }
  end

  defp certificate_expiry do
    %{
      slug: "ssl-certificate-expiry",
      path: "/guides/ssl-certificate-expiry",
      cluster: "uptime",
      intent: :informational,
      primary_query: "ssl certificate expiry monitoring",
      title: "SSL certificate and domain expiry monitoring | PostDeploy",
      meta_description:
        "Certificates now expire every few months and Let's Encrypt no longer emails you first. Check expiry by hand, then get warned 14, 7 and 1 days ahead.",
      nav_label: "Certificate expiry",
      summary:
        "Shorter certificate lifetimes mean more renewals that can fail. Check expiry with openssl, then let a daily scan warn you before the date.",
      hero_badge: "Guide",
      hero_heading: "Renew the certificate before your visitors see the warning",
      hero_description:
        "An expired certificate takes your site down for every visitor at once. Check the date by hand today, then get a warning 14, 7 and 1 days before it.",
      author_name: @author,
      last_verified_on: ~D[2026-09-28],
      code_verified_on: ~D[2026-09-28],
      lastmod: ~D[2026-09-28],
      status: "published",
      related_guide_path: "/guides/backup-heartbeat",
      related_paths: [
        %{"path" => "/monitoring/uptime", "label" => "How HTTP uptime checks work"},
        %{"path" => "/tools/website-health-check", "label" => "Check your site right now"},
        %{"path" => "/monitoring/api", "label" => "API monitoring with keyword checks"},
        %{"path" => "/free-uptime-monitoring", "label" => "What the free uptime trial covers"}
      ],
      cta_heading: "Ask a connected MCP client to add an HTTPS monitor for your site",
      cta_label: "Start your 14-day free trial",
      not_offered: [
        "PostDeploy does not renew, issue, or install certificates.",
        "PostDeploy does not renew or transfer domains.",
        "PostDeploy does not inspect certificate chains, revocation, or cipher settings."
      ],
      sources: [
        %{
          "label" => "Let's Encrypt: Expiration notification service has ended",
          "url" => "https://letsencrypt.org/2025/06/26/expiration-notification-service-has-ended",
          "retrieved" => "2026-09-28"
        },
        %{
          "label" => "Let's Encrypt: Decreasing certificate lifetimes to 45 days",
          "url" => "https://letsencrypt.org/2025/12/02/from-90-to-45",
          "retrieved" => "2026-09-28"
        },
        %{
          "label" => "CA/Browser Forum Ballot SC-081v3: reducing validity periods",
          "url" =>
            "https://cabforum.org/2025/04/11/ballot-sc081v3-introduce-schedule-of-reducing-validity-and-data-reuse-periods/",
          "retrieved" => "2026-09-28"
        },
        %{
          "label" => "OpenSSL: x509 command",
          "url" => "https://docs.openssl.org/3.6/man1/openssl-x509/",
          "retrieved" => "2026-09-28"
        }
      ],
      body_sections: [
        %{
          "heading" => "Certificates expire more often, and nobody emails you first",
          "body" => [
            "Public TLS certificates used to last a year. Since 15 March 2026 the maximum is 200 days. It drops to 100 days in March 2027 and to 47 days in March 2029, under CA/Browser Forum Ballot SC-081v3.",
            "Let's Encrypt moves faster. It plans 64-day certificates on its default profile from February 2027 and 45-day certificates from February 2028. More renewals means more chances for one to fail quietly: a changed DNS record, a firewall rule that blocks the validation request, a renewal timer that stopped with the old server.",
            "The safety net is gone too. Let's Encrypt ended its expiry reminder emails on 4 June 2025. If your renewal breaks today, the first notice is often a browser warning in front of a customer."
          ]
        },
        %{
          "heading" => "Check the expiry date by hand",
          "body" => [
            "Run this against your own hostname. The first command prints the date the served certificate expires. The second exits with status 1 when the certificate expires within 14 days, so a script can act on it.",
            "Pass `-servername` so the server returns the certificate for that hostname. Without it, a shared host can return a default certificate and you read the wrong date."
          ],
          "code" => """
          host=example.com

          echo | openssl s_client -connect "$host:443" -servername "$host" 2>/dev/null |
            openssl x509 -noout -enddate
          # notAfter=Nov 19 21:58:47 2026 GMT

          echo | openssl s_client -connect "$host:443" -servername "$host" 2>/dev/null |
            openssl x509 -noout -checkend $((14 * 86400))
          # Certificate will not expire
          """
        },
        %{
          "heading" => "Let a daily scan do it for every site you run",
          "body" => [
            "A manual check works once. PostDeploy runs it every day at 00:10 UTC for each active HTTP and keyword monitor. It reads the certificate that the monitored HTTPS URL serves, and it looks up the domain's registration expiry.",
            "You get a warning when the certificate or the domain is 14, 7 and 1 days from expiry. Each warning goes out once per threshold, to Email, Slack, Discord, Telegram or a webhook.",
            "There is nothing extra to buy or count. Expiry warnings ride on the uptime monitor you already have, so the same check that tells you the site is down also tells you it is about to be."
          ]
        },
        %{
          "heading" => "Turn the warning on",
          "body" => [
            "First, add an HTTP monitor for the HTTPS address users visit. Ask a connected MCP client, for example: \"Add an uptime monitor for https://example.com in my production project.\"",
            "Then open Notification settings in the PostDeploy console. Add an alert rule for the Monitor trigger \"SSL certificate expiring\" and one for \"Domain expiring\". Point each rule at the channel you read.",
            "Warning: an expiry warning is sent only through an enabled rule for that trigger. A project with only a \"Check down\" rule records nothing for an expiring certificate."
          ]
        },
        %{
          "heading" => "What a 14-day warning tells you",
          "body" => [
            "An automated certificate should never get close to 14 days. Let's Encrypt recommends renewal at about two thirds of the lifetime, which is day 60 for a 90-day certificate. When the 14-day warning arrives, automatic renewal has already failed for weeks.",
            "Treat the first warning as a broken renewal, not a reminder. Run your ACME client's renewal by hand, read its error, and fix the cause: DNS, the validation path, or a stopped timer. Then run the `openssl` command above to confirm the new date.",
            "Domain registration is different. Many registrars renew automatically but fail on an expired payment card. A domain warning usually means a billing problem at the registrar."
          ]
        },
        %{
          "heading" => "Limits to know",
          "body" => [
            "The scan runs once a day from one AWS region. It reads the certificate that this region receives. A CDN that serves different certificates in different regions can show a different date elsewhere.",
            "Domain expiry comes from the public WHOIS record. Some registries, including many country-code domains, do not publish an expiry date there. For those domains PostDeploy sends no domain warning, and the certificate warning still works."
          ]
        }
      ],
      faqs: [
        %{
          "q" => "How far ahead does PostDeploy warn about an expiring certificate?",
          "a" =>
            "At 14, 7 and 1 days before expiry, once per threshold, through the alert rules you enable."
        },
        %{
          "q" => "Does Let's Encrypt still send expiry emails?",
          "a" => "No. Let's Encrypt ended its expiration notification emails on 4 June 2025."
        },
        %{
          "q" => "Does PostDeploy renew my certificate?",
          "a" =>
            "No. It warns you before the expiry date. Your ACME client or certificate provider renews it."
        },
        %{
          "q" => "Do expiry warnings use up a monitor?",
          "a" => "No extra one. They run on each active HTTP or keyword monitor you already have."
        }
      ]
    }
  end
end
