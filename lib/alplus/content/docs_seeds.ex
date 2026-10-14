defmodule Alplus.Content.DocsSeeds do
  @moduledoc """
  The Help Center at `/docs` (issue #168): one hub `Page` and the first
  eleven `Guide` rows under `/docs/`.

  Docs own product configuration: keys, Sentry client setup, the heartbeat protocol,
  Measure installation, and MCP access. Guides own platform procedures and
  alternatives own vendor evaluations, so a docs page links to those instead
  of repeating them.

  Every code sample here ran against a disposable project on this codebase.
  The Observe pages ran on 2026-10-12 with `@sentry/node` 11.6.0,
  `sentry-ruby` 7.1.0 and `sentry` 13.5.1; the other pages ran on 2026-09-15.
  Only the ingest host was local. Update `code_verified_on` for a page only
  when its changed samples run again; a copy edit keeps the date.

  Seeded separately from `Alplus.Content.Seeds`, same reasoning as the other
  pillar seed modules. `Seeds.run/0` calls this one.
  """

  alias Alplus.Billing.Package
  alias Alplus.Content

  @lastmod ~D[2026-09-15]
  @verified ~D[2026-09-15]
  @observe_verified ~D[2026-10-12]
  @author "Paul"
  @ingest "https://ingest.postdeploy.dev"
  @mcp "https://postdeploy.dev/mcp"
  @issuer "https://postdeploy.dev"

  def run do
    {:ok, _page} =
      Content.create_page(hub(),
        authorize?: false,
        upsert?: true,
        upsert_identity: :unique_slug,
        upsert_fields: :replace_all
      )

    Enum.each(docs(), fn attrs ->
      {:ok, _guide} =
        Content.create_guide(
          Map.merge(
            %{cluster: "docs", intent: :informational, author_name: @author, lastmod: @lastmod},
            attrs
          ),
          authorize?: false,
          upsert?: true,
          upsert_identity: :unique_slug,
          upsert_fields: :replace_all
        )
    end)

    :ok
  end

  defp hub do
    %{
      slug: "docs",
      path: "/docs",
      cluster: "docs",
      intent: :navigational,
      primary_query: "postdeploy docs",
      title: "Docs: set up monitors, errors and analytics | PostDeploy",
      meta_description:
        "Set up a PostDeploy project, connect your agent, and send a first heartbeat, error or pageview with tested setup steps.",
      nav_label: "Docs",
      summary:
        "The PostDeploy Help Center: project setup, heartbeats, error tracking with Sentry clients, Measure installation, and MCP access.",
      hero_heading: "Help for the software you run after deploy",
      hero_description:
        "Set up one project, connect your agent, and send the first real signal. Every setup sample on these pages ran against a PostDeploy project before publication.",
      group: "core",
      priority: "0.8",
      lastmod: @lastmod,
      body_sections: [],
      faqs: []
    }
  end

  defp docs do
    [
      get_started(),
      monitoring(),
      heartbeats(),
      observe(),
      javascript(),
      ruby(),
      elixir(),
      analytics(),
      product_analytics(),
      mcp(),
      mcp_changelog(),
      projects_and_keys()
    ]
  end

  # -- Get started ------------------------------------------------------

  defp get_started do
    %{
      slug: "docs-get-started",
      path: "/docs/get-started",
      primary_query: "postdeploy getting started",
      title: "Get started: first project and first signal | PostDeploy Docs",
      meta_description:
        "Create an organization and project, connect an MCP client, and send your first heartbeat to PostDeploy in about ten minutes.",
      nav_label: "Get started",
      summary: "From sign-up to one project that receives a real signal.",
      hero_heading: "Get your first signal",
      hero_description:
        "At the end of this page, one project shows a heartbeat you sent. The same project then takes error tracking and analytics without a second account.",
      code_verified_on: @verified,
      last_verified_on: @verified,
      cta_heading: "Create the project now.",
      body_sections: [
        %{
          "heading" => "Before you begin",
          "list" => [
            "A PostDeploy account. The trial runs #{Package.trial_days()} days and needs no card.",
            "An MCP client that supports remote servers with OAuth, for example the coding agent you already use.",
            "A terminal with `curl`, to send the first heartbeat."
          ]
        },
        %{
          "heading" => "Create the organization and project",
          "body" => [
            "People create organizations and projects in the dashboard. Everything inside a project, such as monitors, keys and sources, comes from your agent."
          ],
          "steps" => [
            %{"text" => "Register at [postdeploy.dev/register](/register)."},
            %{
              "text" =>
                "On \"Create your organization\", enter a name and select \"Create organization\"."
            },
            %{
              "text" =>
                "Under \"Create your first project\", enter a project name and select \"Create project\". The dashboard opens \"Connect an agent\"."
            }
          ]
        },
        %{
          "heading" => "Connect your agent",
          "steps" => [
            %{
              "text" =>
                "Copy the setup prompt from \"Connect an agent\" and give it to your MCP client. It names this endpoint and OAuth.",
              "code" =>
                "Set up a remote MCP server named \"my-project\" for this project.\nEndpoint: #{@mcp}\nAuthentication: OAuth.",
              "filename" => "Prompt",
              "language" => "text"
            },
            %{
              "text" =>
                "Your client opens a browser. Sign in, choose the organization and project, clear any permission the client does not need, and select \"Allow access\"."
            },
            %{
              "text" =>
                "Return to \"Connect an agent\" and select \"Check connection\". The screen shows \"Your agent is connected\"."
            }
          ],
          "after" => [
            "Read [Connect an MCP client](/docs/mcp) for permissions, token lifetimes and revocation."
          ]
        },
        %{
          "heading" => "Send the first heartbeat",
          "body" => [
            "A heartbeat is the fastest first signal, because it needs no SDK and no deploy."
          ],
          "steps" => [
            %{
              "text" =>
                "Ask your agent to create a heartbeat monitor. The response contains a token that starts with `hb_`. PostDeploy shows it once.",
              "code" =>
                "Create a heartbeat monitor named nightly-backup that expects a ping every day, with a one hour grace period. Show me the heartbeat token.",
              "filename" => "Prompt",
              "language" => "text"
            },
            %{
              "text" => "Send a ping. The server answers `202 Accepted`.",
              "code" =>
                "export POSTDEPLOY_HEARTBEAT_TOKEN=hb_your_token\ncurl -i \"#{@ingest}/h/$POSTDEPLOY_HEARTBEAT_TOKEN\"",
              "filename" => "Terminal",
              "language" => "shell"
            },
            %{
              "text" =>
                "Open Monitor in the dashboard. The row \"nightly-backup\" shows a recent check, and its detail screen lists it under \"Recent checks\" as Up."
            }
          ]
        },
        %{
          "heading" => "Add the next signal",
          "rows" => [
            %{
              "term" => "Production errors",
              "detail" =>
                "Set the DSN of your Sentry client. Start at [Capture production errors](/docs/observe)."
            },
            %{
              "term" => "Pageviews and events",
              "detail" =>
                "Add one script tag to your site. Follow [Install Measure](/docs/analytics)."
            },
            %{
              "term" => "Uptime checks",
              "detail" =>
                "Ask your agent to check a URL. Read [Choose uptime checks or heartbeats](/docs/monitoring)."
            }
          ]
        },
        %{
          "heading" => "Troubleshoot",
          "rows" => [
            %{
              "term" => "There is no button to create a key or monitor",
              "detail" =>
                "The dashboard is for review. Your connected agent creates monitors, keys and sources."
            },
            %{
              "term" => "The heartbeat token is lost",
              "detail" =>
                "PostDeploy shows a token once. Ask your agent to reissue the heartbeat token, then approve the request under \"Pending confirmations\" on the project MCP screen."
            },
            %{
              "term" => "curl prints 404",
              "detail" =>
                "The token is wrong or was reissued. Copy the token from the latest agent response."
            }
          ]
        }
      ],
      not_offered: [
        "The dashboard does not create monitors, keys or sources. A connected MCP client does.",
        "A heartbeat that stops arriving does not send an alert. Read [missed runs](/docs/monitoring/heartbeats#missed-runs) before you depend on it."
      ],
      related_paths: [
        %{"path" => "/docs/mcp", "label" => "Connect an MCP client"},
        %{"path" => "/docs/projects-and-keys", "label" => "Projects and keys"},
        %{"path" => "/pricing", "label" => "Pricing and trial limits"}
      ]
    }
  end

  # -- Monitor ------------------------------------------------------------

  defp monitoring do
    %{
      slug: "docs-monitoring",
      path: "/docs/monitoring",
      primary_query: "postdeploy uptime and heartbeat setup",
      title: "Monitor: uptime checks and heartbeats | PostDeploy Docs",
      meta_description:
        "Choose between PostDeploy uptime checks, which send requests to you, and heartbeats, which your scheduled jobs send to PostDeploy.",
      nav_label: "Monitor",
      summary: "Choose uptime checks, heartbeats, or both.",
      hero_heading: "Choose uptime checks or heartbeats",
      hero_description:
        "Uptime checks request something you serve. Heartbeats receive a report from something you schedule. Most projects need both, in the same project.",
      last_verified_on: @verified,
      body_sections: [
        %{
          "heading" => "Two monitoring models",
          "rows" => [
            %{
              "term" => "Uptime and API checks",
              "detail" =>
                "PostDeploy sends the request on a schedule: HTTP, keyword, TCP or DNS. Checks run from one AWS region. Failed checks open an incident and notify your alert channels."
            },
            %{
              "term" => "Heartbeats",
              "detail" =>
                "Your job sends the request: start, finish or fail. PostDeploy records each finish and fail as a check. A fail opens an incident at once."
            }
          ]
        },
        %{
          "heading" => "Pick the model for each thing you run",
          "list" => [
            "A website, API or health endpoint: an HTTP or keyword check.",
            "A database port or mail server: a TCP check.",
            "A DNS record you depend on: a DNS check.",
            "A cron job, backup, queue worker or scheduled workflow: a heartbeat."
          ]
        },
        %{
          "heading" => "Create a monitor",
          "body" => [
            "Ask your connected agent. It creates the monitor through MCP, and the Monitor screen shows the result. The package sets the shortest interval."
          ],
          "code" =>
            "Create an HTTP monitor for https://example.com/health that checks every 5 minutes and alerts by email.",
          "filename" => "Prompt",
          "language" => "text"
        },
        %{
          "heading" => "Get alerts",
          "body" => [
            "Alerts go to email, Slack, Discord, a webhook or Telegram. Ask your agent to add the channel to the project, then trigger a test failure before you rely on it."
          ]
        }
      ],
      not_offered: [
        "No ICMP ping, UDP, or browser checks.",
        "No multi-region confirmation. Checks run from one AWS region.",
        "A heartbeat that stops arriving does not open an incident or send an alert."
      ],
      related_paths: [
        %{"path" => "/docs/monitoring/heartbeats", "label" => "Heartbeat protocol reference"},
        %{"path" => "/monitoring/uptime", "label" => "How uptime checks work"},
        %{"path" => "/monitoring/api", "label" => "API checks with keyword assertions"},
        %{"path" => "/guides", "label" => "Heartbeat guides for each scheduler"}
      ]
    }
  end

  defp heartbeats do
    %{
      slug: "docs-monitoring-heartbeats",
      path: "/docs/monitoring/heartbeats",
      primary_query: "heartbeat ping url start finish fail",
      title: "Heartbeat pings: start, finish and fail | PostDeploy Docs",
      meta_description:
        "Send start, finish and fail heartbeats to PostDeploy with curl or an exit code, make retries safe, and know what a missed run does.",
      nav_label: "Heartbeats",
      summary: "The heartbeat URL, its states, exit codes, retries and missed runs.",
      hero_heading: "Send heartbeats from a scheduled job",
      hero_description:
        "A heartbeat URL records each run your job reports. Send finish when the job succeeds and fail when it does not. PostDeploy opens an incident on the first fail.",
      code_verified_on: @verified,
      last_verified_on: @verified,
      body_sections: [
        %{
          "heading" => "Before you begin",
          "list" => [
            "A connected agent with the Monitor write permission.",
            "A job that can make one outbound HTTPS request with `curl`, `wget` or any HTTP client."
          ]
        },
        %{
          "heading" => "Create a heartbeat monitor",
          "steps" => [
            %{
              "text" =>
                "Ask your agent for a heartbeat monitor. Give it the expected interval and a grace period.",
              "code" =>
                "Create a heartbeat monitor named nightly-backup. It runs every day. Use a one hour grace period. Show me the heartbeat token.",
              "filename" => "Prompt",
              "language" => "text"
            },
            %{
              "text" =>
                "Store the token from the response as a secret, for example `POSTDEPLOY_HEARTBEAT_TOKEN`. It starts with `hb_` and PostDeploy shows it once."
            }
          ]
        },
        %{
          "heading" => "Report a run",
          "body" => [
            "Send start before the job and the exit code after it, so a failed job records fail. GET and POST behave the same. The token in the URL is the only authentication, so treat the URL as a secret. No header is needed."
          ],
          "code" =>
            "curl -fsS \"#{@ingest}/h/$POSTDEPLOY_HEARTBEAT_TOKEN?state=start\"\n/usr/local/bin/nightly-backup.sh\ncurl -fsS \"#{@ingest}/h/$POSTDEPLOY_HEARTBEAT_TOKEN/$?\"",
          "filename" => "nightly-backup.sh",
          "language" => "shell",
          "rows" => [
            %{
              "term" => "`state=start`",
              "detail" => "Marks the run as started. It records no check."
            },
            %{
              "term" => "`state=finish`, or no state",
              "detail" =>
                "Records an Up check. An open incident resolves after two passes in a row."
            },
            %{
              "term" => "`state=fail`",
              "detail" =>
                "Records a Down check, opens an incident at once, and notifies your alert channels."
            }
          ]
        },
        %{
          "heading" => "Report the exit code",
          "body" => [
            "Append the exit code to the URL. `0` records finish. Any other value records fail. The exit code wins over a `state` parameter."
          ],
          "code" =>
            "0 2 * * * /usr/local/bin/nightly-backup.sh; curl -fsS \"#{@ingest}/h/$POSTDEPLOY_HEARTBEAT_TOKEN/$?\" > /dev/null",
          "filename" => "crontab",
          "language" => "shell"
        },
        %{
          "heading" => "Make retries safe",
          "body" => [
            "Add a `ping_id` when your job retries the request. PostDeploy records one check per `ping_id` for 24 hours and answers `202` to each duplicate. Use one value per run, not per request."
          ],
          "code" =>
            "curl -fsS --retry 3 \"#{@ingest}/h/$POSTDEPLOY_HEARTBEAT_TOKEN/0?ping_id=nightly-$(date +%F)\"",
          "filename" => "Terminal",
          "language" => "shell",
          "after" => [
            "A `ping_id` has 1 to 128 characters: letters, digits, `_`, `.` and `-`."
          ]
        },
        %{
          "heading" => "Missed runs",
          "callout" => %{
            "tone" => "caution",
            "lead" => "Warning",
            "body" =>
              "PostDeploy records the pings it receives. It does not alert when an expected ping never arrives. After at least one check, a monitor with no ping for twice the interval, and at least 5 minutes, shows Late on the Monitor screen. A monitor that never received a check stays waiting, and a Down monitor stays Down. No incident opens and no alert is sent."
          },
          "body" => [
            "A received fail is detected at once, because your job reports it. A run that never starts sends nothing, so nothing is detected. Report fail from the job wrapper wherever the job can fail, and use a separate watchdog if a missed run must alert someone."
          ]
        },
        %{
          "heading" => "Verify",
          "steps" => [
            %{
              "text" => "Send one ping and read the status line.",
              "code" =>
                "curl -i \"#{@ingest}/h/$POSTDEPLOY_HEARTBEAT_TOKEN\"\n# Expect: HTTP/1.1 202 Accepted",
              "filename" => "Terminal",
              "language" => "shell"
            },
            %{
              "text" =>
                "Open Monitor. The monitor row shows a check time. Its detail screen lists the ping under \"Recent checks\" as Up."
            },
            %{
              "text" =>
                "Send `/1` once to test failure. The detail screen shows a Down check and an open incident. Send two passes to resolve it."
            }
          ]
        },
        %{
          "heading" => "Troubleshoot",
          "rows" => [
            %{
              "term" => "A job stopped and no alert arrived",
              "detail" =>
                "A missing ping is not detected. Send an explicit fail from the job. After the first check, watch for Late on the Monitor screen."
            },
            %{
              "term" => "A retried ping adds no check",
              "detail" =>
                "The same `ping_id` within 24 hours is a duplicate. Use one `ping_id` per run."
            },
            %{
              "term" => "The monitor shows Up but the incident is still open",
              "detail" =>
                "An incident resolves after two passes in a row. Wait for the next successful run."
            },
            %{
              "term" => "The URL returns 404",
              "detail" =>
                "The token is unknown or was reissued. Ask your agent to reissue the token and approve the request in the dashboard."
            },
            %{
              "term" => "Pings return 202 but record nothing",
              "detail" =>
                "The monitor is paused or the subscription is inactive. Ask your agent to resume the monitor."
            }
          ]
        }
      ],
      not_offered: [
        "A missed run does not open an incident or send an alert.",
        "The URL token is the only authentication. Anyone with the URL can report a run.",
        "Reissuing a token is a destructive action. An owner or admin approves it in the dashboard."
      ],
      related_paths: [
        %{"path" => "/guides", "label" => "Heartbeat guides for each scheduler"},
        %{
          "path" => "/guides/github-actions-heartbeat",
          "label" => "Monitor a GitHub Actions schedule"
        },
        %{
          "path" => "/guides/kubernetes-cronjob-heartbeat",
          "label" => "Monitor a Kubernetes CronJob"
        },
        %{"path" => "/monitoring/cron-jobs", "label" => "How cron job monitoring works"}
      ]
    }
  end

  # -- Observe ------------------------------------------------------------

  defp observe do
    %{
      slug: "docs-observe",
      lastmod: @observe_verified,
      path: "/docs/observe",
      primary_query: "sentry compatible error tracking",
      title: "Observe: send errors from your Sentry client | PostDeploy Docs",
      meta_description:
        "Create a server-side Observe key, set it as the DSN of your Sentry client for JavaScript, Ruby or Elixir, and confirm the first grouped issue.",
      nav_label: "Observe",
      summary: "Create an ingest key and set it as the DSN of your Sentry client.",
      hero_heading: "Capture production errors",
      hero_description:
        "Set the DSN of your Sentry client to an Observe key. Errors arrive grouped into issues, with the release, environment and user you attach.",
      last_verified_on: @observe_verified,
      body_sections: [
        %{
          "heading" => "Choose your runtime",
          "rows" => [
            %{
              "term" => "[JavaScript](/docs/observe/javascript)",
              "detail" => "`@sentry/node`, for Node.js servers and scripts."
            },
            %{
              "term" => "[Ruby](/docs/observe/ruby)",
              "detail" => "`sentry-ruby` for Rack and plain Ruby, and `sentry-rails` for Rails."
            },
            %{
              "term" => "[Elixir](/docs/observe/elixir)",
              "detail" => "`sentry`, for Elixir, Plug and Phoenix."
            }
          ]
        },
        %{
          "heading" => "Get an ingest key",
          "steps" => [
            %{
              "text" =>
                "Ask your connected agent to create an Observe source for one environment.",
              "code" =>
                "Create an Observe source named api for the production environment. Show me the key.",
              "filename" => "Prompt",
              "language" => "text"
            },
            %{
              "text" =>
                "Store the key as `POSTDEPLOY_API_KEY` in your server secrets. It starts with `obs_` and PostDeploy shows it once."
            }
          ],
          "callout" => %{
            "tone" => "tip",
            "lead" => "Tip",
            "body" =>
              "Create one source per environment. The key sets the environment, so an event sent as staging with a production key is stored as production."
          }
        },
        %{
          "heading" => "Set the DSN",
          "body" => [
            "Build the DSN from your key and the PostDeploy ingest host. Use `1` as the project number. Sentry clients require a number, and the key selects your project."
          ],
          "code" => "SENTRY_DSN=https://obs_your_key@ingest.postdeploy.dev/1",
          "filename" => "Server environment",
          "language" => "shell",
          "after" => [
            "Each runtime guide shows where the client reads the DSN. PostDeploy has been tested with the Sentry clients for JavaScript on Node.js, Ruby, Elixir and Rust."
          ]
        },
        %{
          "heading" => "What each event carries",
          "body" => [
            "Each event carries the exception type, message and stack trace, the release your client sets, and the environment from the key. It also carries the user, tags and context you attach. Observe groups matching events into one issue."
          ]
        },
        %{
          "heading" => "Verify",
          "body" => [
            "Open Observe in the dashboard. The title counts open issues, and the table shows the error with its source and environment, for example \"api, production\"."
          ]
        }
      ],
      not_offered: [
        "Observe records the error and message events a Sentry client sends. It does not ingest logs, collect traces, or record session replay.",
        "Browser Sentry clients cannot send to Observe. Run the client in server code."
      ],
      related_paths: [
        %{"path" => "/docs/projects-and-keys", "label" => "Rotate and revoke keys"},
        %{"path" => "/error-tracking", "label" => "How Observe groups and triages errors"},
        %{
          "path" => "/guides/investigate-errors-after-release",
          "label" => "Investigate errors after a release"
        }
      ]
    }
  end

  defp javascript do
    %{
      slug: "docs-observe-javascript",
      lastmod: @observe_verified,
      path: "/docs/observe/javascript",
      primary_query: "node.js error tracking setup",
      title: "JavaScript error tracking with @sentry/node | PostDeploy Docs",
      meta_description:
        "Set an Observe key as the DSN of @sentry/node, capture uncaught and handled Node.js errors with user and context, flush before exit, and verify the issue.",
      nav_label: "JavaScript",
      summary: "Node.js setup for @sentry/node with an Observe DSN.",
      hero_heading: "Track errors in JavaScript",
      hero_description:
        "Install @sentry/node and call init once with your Observe DSN. Uncaught exceptions and the errors you capture reach Observe, grouped into issues, with the user and context you set.",
      code_verified_on: @observe_verified,
      last_verified_on: @observe_verified,
      body_sections: [
        %{
          "heading" => "Before you begin",
          "list" => [
            "A Node.js version that `@sentry/node` supports.",
            "An Observe key that starts with `obs_`. Read [Get an ingest key](/docs/observe#get-an-ingest-key).",
            "Version 11 of `@sentry/node`. This page uses its API."
          ]
        },
        %{
          "heading" => "Install",
          "code" => "npm install @sentry/node",
          "filename" => "Terminal",
          "language" => "shell",
          "after" => [
            "Set `SENTRY_DSN` in the environment of every process that reports errors. Use `https://obs_your_key@ingest.postdeploy.dev/1`."
          ]
        },
        %{
          "heading" => "Configure",
          "body" => [
            "Call `init` once, before your app starts work. Set user, tags and context inside `withScope`, so they apply to one request or job."
          ],
          "code" => """
          import * as Sentry from "@sentry/node";

          Sentry.init({
            dsn: process.env.SENTRY_DSN,
            release: "1.0.0",
          });

          Sentry.withScope((scope) => {
            scope.setUser({ id: "user_123", email: "jane@example.com" });
            scope.setTag("plan", "pro");
            scope.setContext("checkout", { cart_items: 3 });

            try {
              throw new Error("Payment provider timed out");
            } catch (err) {
              Sentry.captureException(err);
            }
          });

          await Sentry.flush(2000);
          """,
          "filename" => "app.mjs",
          "language" => "javascript"
        },
        %{
          "heading" => "What is captured without code",
          "body" => [
            "`init` adds handlers for uncaught exceptions and unhandled promise rejections. After an uncaught exception, the client sends the event, then exits the process with code 1."
          ]
        },
        %{
          "heading" => "Flush before a process exits",
          "body" => [
            "The client sends events in the background. Call `await Sentry.flush(timeoutMs)` at the end of a script or job. It resolves `true` when the events are sent and `false` when the timeout ends first."
          ]
        },
        %{
          "heading" => "Verify",
          "steps" => [
            %{
              "text" => "Run the script.",
              "code" => "SENTRY_DSN=https://obs_your_key@ingest.postdeploy.dev/1 node app.mjs",
              "filename" => "Terminal",
              "language" => "shell"
            },
            %{
              "text" =>
                "Open Observe. The table shows \"Error: Payment provider timed out\" with its source and environment, and 1 event."
            },
            %{
              "text" =>
                "If nothing arrives, test the key. `400` means the key is valid. `401` means it is not.",
              "code" =>
                "curl -s -o /dev/null -w \"%{http_code}\\n\" -X POST \"#{@ingest}/api/1/envelope/?sentry_key=$POSTDEPLOY_API_KEY\" \\\n  -H \"Content-Type: application/x-sentry-envelope\" -d 'test'",
              "filename" => "Terminal",
              "language" => "shell"
            }
          ]
        },
        %{
          "heading" => "Troubleshoot",
          "rows" => [
            %{
              "term" => "`flush` returns false but the event arrives",
              "detail" =>
                "The send took longer than the timeout. Pass a longer timeout, for example `flush(5000)`."
            },
            %{
              "term" => "The environment is not the one in `init`",
              "detail" =>
                "The key sets the environment. Use a key from a source for that environment."
            },
            %{
              "term" => "`init` prints `Invalid Sentry Dsn`",
              "detail" =>
                "Some older keys contain a hyphen, which the JavaScript client rejects. Rotate the source once and use the new key in your DSN."
            },
            %{
              "term" => "The browser console shows a blocked request",
              "detail" =>
                "Browser Sentry clients cannot send to Observe. Run the client in Node.js."
            }
          ]
        },
        %{
          "heading" => "Existing @postdeploy/sdk installs",
          "body" => [
            "Installs of `@postdeploy/sdk` keep sending to the same key and host. Use `@sentry/node` for new setups."
          ],
          "code" => """
          import { init, captureException, withScope, setUser, setTag, setContext, flush } from "@postdeploy/sdk/node";

          init({
            key: process.env.POSTDEPLOY_API_KEY,
            environment: "production",
            release: "1.0.0",
          });

          await withScope(async () => {
            setUser({ id: "user_123", email: "jane@example.com" });
            setTag("plan", "pro");
            setContext("checkout", { cart_items: 3 });

            try {
              throw new Error("Payment provider timed out");
            } catch (err) {
              captureException(err, { context: { feature: "checkout" } });
            }

            await flush(2000);
          });
          """,
          "filename" => "app.mjs",
          "language" => "javascript",
          "rows" => [
            %{
              "term" => "`@postdeploy/sdk/node`",
              "detail" =>
                "Node.js servers and scripts. Captures `uncaughtException` and `unhandledRejection`."
            },
            %{
              "term" => "`@postdeploy/sdk/cloudflare`",
              "detail" =>
                "Cloudflare Workers. Wrap your handlers with `wrapHandler` and `wrapScheduled`."
            },
            %{
              "term" => "A rejected key drops events without a warning",
              "detail" =>
                "In 0.5.0 this holds even with `debug: true`. Test the key with the curl command above."
            },
            %{
              "term" => "`setUser` has no effect on a server",
              "detail" => "Call it inside `withScope`, once per request or job."
            }
          ]
        }
      ],
      not_offered: [
        "The DSN holds a server secret. Do not put it in code that runs in a browser."
      ],
      related_paths: [
        %{"path" => "/docs/observe", "label" => "Choose a runtime and get a key"},
        %{"path" => "/docs/monitoring/heartbeats", "label" => "Heartbeat protocol reference"},
        %{"path" => "/error-tracking", "label" => "How Observe groups errors"}
      ]
    }
  end

  defp ruby do
    %{
      slug: "docs-observe-ruby",
      lastmod: @observe_verified,
      path: "/docs/observe/ruby",
      primary_query: "rails error tracking setup",
      title: "Ruby and Rails error tracking with sentry-ruby | PostDeploy Docs",
      meta_description:
        "Set an Observe key as the DSN of sentry-ruby in Rails or Rack, capture exceptions with user and context, and verify the issue.",
      nav_label: "Ruby",
      summary: "Rails, Rack and plain Ruby setup for sentry-ruby with an Observe DSN.",
      hero_heading: "Track errors in Ruby and Rails",
      hero_description:
        "Add sentry-ruby with your Observe DSN. In Rails, add sentry-rails. In Rack apps, add the middleware. In scripts, call capture yourself.",
      code_verified_on: @observe_verified,
      last_verified_on: @observe_verified,
      body_sections: [
        %{
          "heading" => "Before you begin",
          "list" => [
            "Ruby 2.7 or later.",
            "An Observe key that starts with `obs_`. Read [Get an ingest key](/docs/observe#get-an-ingest-key).",
            "Version 7 of `sentry-ruby`. This page uses its API."
          ]
        },
        %{
          "heading" => "Install",
          "code" => "# Gemfile\ngem \"sentry-ruby\"\ngem \"sentry-rails\" # Rails only",
          "filename" => "Gemfile",
          "language" => "ruby",
          "after" => [
            "Run `bundle install`, then set `SENTRY_DSN` in the environment of every process that reports errors. Use `https://obs_your_key@ingest.postdeploy.dev/1`."
          ]
        },
        %{
          "heading" => "Rails",
          "body" => [
            "Create an initializer. `sentry-rails` reports the exceptions that Rails rescues while it handles a request. Attach the user in a `before_action`."
          ],
          "code" => """
          # config/initializers/sentry.rb
          Sentry.init do |config|
            config.dsn = ENV["SENTRY_DSN"]
            config.release = ENV["GIT_SHA"]
          end

          # app/controllers/application_controller.rb
          class ApplicationController < ActionController::Base
            before_action do
              Sentry.set_user(id: current_user.id, email: current_user.email) if current_user
            end
          end
          """,
          "filename" => "config/initializers/sentry.rb",
          "language" => "ruby"
        },
        %{
          "heading" => "Rack",
          "body" => [
            "Add the middleware. It reports the error, then raises it again so your error page still renders."
          ],
          "code" => """
          require "sentry-ruby"

          Sentry.init do |config|
            config.dsn = ENV["SENTRY_DSN"]
          end

          use Sentry::Rack::CaptureExceptions

          run lambda { |env|
            Sentry.set_user(id: "user_rack_1")
            raise "Checkout failed" if env["PATH_INFO"] == "/boom"
            [200, { "content-type" => "text/plain" }, ["ok"]]
          }
          """,
          "filename" => "config.ru",
          "language" => "ruby"
        },
        %{
          "heading" => "Scripts and tasks",
          "body" => [
            "Call `Sentry.init`, then capture errors and messages yourself. The client sends pending events when the process exits."
          ],
          "code" => """
          require "sentry-ruby"

          Sentry.init do |config|
            config.dsn = ENV["SENTRY_DSN"]
            config.release = ENV["GIT_SHA"]
          end

          Sentry.set_user(id: "user_456", email: "sam@example.com")
          Sentry.set_tags(plan: "team")
          Sentry.set_extras(order_id: "ord_789")

          begin
            raise "Invoice total is negative"
          rescue => e
            Sentry.capture_exception(e)
          end

          Sentry.capture_message("Low disk space", level: :warning)
          """,
          "filename" => "report.rb",
          "language" => "ruby"
        },
        %{
          "heading" => "Verify",
          "steps" => [
            %{
              "text" => "Run the script.",
              "code" => "SENTRY_DSN=https://obs_your_key@ingest.postdeploy.dev/1 ruby report.rb",
              "filename" => "Terminal",
              "language" => "shell"
            },
            %{
              "text" =>
                "Open Observe. The table shows \"RuntimeError: Invoice total is negative\" as an error and \"Low disk space\" as a warning."
            },
            %{
              "text" =>
                "If nothing arrives, test the key. `400` means the key is valid. `401` means it is not.",
              "code" =>
                "curl -s -o /dev/null -w \"%{http_code}\\n\" -X POST \"#{@ingest}/api/1/envelope/?sentry_key=$POSTDEPLOY_API_KEY\" \\\n  -H \"Content-Type: application/x-sentry-envelope\" -d 'test'",
              "filename" => "Terminal",
              "language" => "shell"
            }
          ]
        },
        %{
          "heading" => "Troubleshoot",
          "rows" => [
            %{
              "term" => "The environment is not the one in your configuration",
              "detail" =>
                "The key sets the environment. Use a key from a source for that environment."
            },
            %{
              "term" => "The error page still renders",
              "detail" =>
                "The middleware raises the error again after it reports it. This is expected."
            }
          ]
        },
        %{
          "heading" => "Existing postdeploy gem installs",
          "body" => [
            "Installs of the `postdeploy` gem keep sending to the same key and host. Use `sentry-ruby` for new setups."
          ],
          "code" => """
          require "postdeploy"

          PostDeploy.configure do |config|
            config.environment = "production"
            config.release = ENV["GIT_SHA"]
          end

          PostDeploy.set_user(id: "user_456", email: "sam@example.com")
          PostDeploy.set_tag("plan", "team")
          PostDeploy.set_context("order", { order_id: "ord_789" })

          begin
            raise ArgumentError, "Invoice total is negative"
          rescue => e
            PostDeploy.capture_exception(e, context: { feature: "billing" })
          end

          PostDeploy.flush
          """,
          "filename" => "report.rb",
          "language" => "ruby",
          "rows" => [
            %{
              "term" => "Rails",
              "detail" =>
                "The gem's Railtie adds `PostDeploy::RackMiddleware` and reports errors from `Rails.error`. Do not add the middleware again."
            },
            %{
              "term" => "Rack",
              "detail" =>
                "Add `use PostDeploy::RackMiddleware` first. It reports the error, then raises it again."
            },
            %{
              "term" => "A rake task or script reports nothing",
              "detail" =>
                "Call `PostDeploy.flush` before the process exits. Version 0.2.0 does not flush at exit."
            }
          ]
        }
      ],
      not_offered: [
        "The DSN holds a server secret. Do not put it in code that runs in a browser."
      ],
      related_paths: [
        %{"path" => "/docs/observe", "label" => "Choose a runtime and get a key"},
        %{"path" => "/docs/monitoring/heartbeats", "label" => "Heartbeat protocol reference"},
        %{"path" => "/error-tracking", "label" => "How Observe groups errors"}
      ]
    }
  end

  defp elixir do
    %{
      slug: "docs-observe-elixir",
      lastmod: @observe_verified,
      path: "/docs/observe/elixir",
      primary_query: "phoenix error tracking setup",
      title: "Elixir and Phoenix error tracking with sentry | PostDeploy Docs",
      meta_description:
        "Set an Observe key as the DSN of the sentry package in a Phoenix or Plug app, capture crashes through the logger handler, attach user and context, and verify the issue.",
      nav_label: "Elixir",
      summary: "Phoenix, Plug and script setup for the sentry package with an Observe DSN.",
      hero_heading: "Track errors in Elixir and Phoenix",
      hero_description:
        "Configure the sentry package with your Observe DSN and attach its logger handler. Process crashes reach Observe through the logger, with the request and user you attach.",
      code_verified_on: @observe_verified,
      last_verified_on: @observe_verified,
      body_sections: [
        %{
          "heading" => "Before you begin",
          "list" => [
            "An Elixir project with a supervision tree.",
            "An Observe key that starts with `obs_`. Read [Get an ingest key](/docs/observe#get-an-ingest-key).",
            "Version 13.5 of the `sentry` package. It needs `jason` and `finch`."
          ]
        },
        %{
          "heading" => "Install",
          "code" =>
            "# mix.exs\n{:sentry, \"~> 13.5\"},\n{:jason, \"~> 1.4\"},\n{:finch, \"~> 0.21\"}",
          "filename" => "mix.exs",
          "language" => "elixir",
          "after" => [
            "Run `mix deps.get`, then set `SENTRY_DSN` in the environment of every process that reports errors. Use `https://obs_your_key@ingest.postdeploy.dev/1`."
          ]
        },
        %{
          "heading" => "Phoenix and Plug",
          "body" => [
            "Read the DSN in `config/runtime.exs`. Attach the logger handler when your application starts, so process crashes and error logs reach Observe. `Sentry.PlugContext` adds the request to each error."
          ],
          "code" => """
          # config/runtime.exs
          config :sentry,
            dsn: System.get_env("SENTRY_DSN"),
            release: System.get_env("GIT_SHA")

          # lib/my_app/application.ex, in start/2
          :logger.add_handler(:sentry, Sentry.LoggerHandler, %{
            config: %{metadata: [:request_id]}
          })

          # lib/my_app_web/router.ex, in each browser or API pipeline
          plug Sentry.PlugContext
          """,
          "filename" => "runtime.exs",
          "language" => "elixir"
        },
        %{
          "heading" => "Capture an error yourself",
          "body" => [
            "Pass the stacktrace with the exception."
          ],
          "code" => """
          Sentry.Context.set_user_context(%{id: "user_789", email: "ada@example.com"})
          Sentry.Context.set_tags_context(%{plan: "scale"})
          Sentry.Context.set_extra_context(%{queue: "mailers"})

          try do
            raise ArgumentError, "Mailer template is missing"
          rescue
            exception ->
              Sentry.capture_exception(exception, stacktrace: __STACKTRACE__)
          end

          Sentry.capture_message("Low disk space", level: :warning)
          """,
          "filename" => "lib/my_app/mailer.ex",
          "language" => "elixir"
        },
        %{
          "heading" => "Verify",
          "steps" => [
            %{
              "text" => "Run a one-file check with the same key.",
              "code" => """
              Mix.install(
                [{:sentry, "~> 13.5"}, {:jason, "~> 1.4"}, {:finch, "~> 0.21"}],
                config: [sentry: [dsn: System.fetch_env!("SENTRY_DSN")]]
              )

              try do
                raise ArgumentError, "Mailer template is missing"
              rescue
                exception -> Sentry.capture_exception(exception, stacktrace: __STACKTRACE__)
              end

              Process.sleep(2000)
              """,
              "filename" => "check.exs",
              "language" => "elixir"
            },
            %{
              "text" =>
                "Run it with `SENTRY_DSN=https://obs_your_key@ingest.postdeploy.dev/1 elixir check.exs`."
            },
            %{
              "text" =>
                "Open Observe. The table shows \"ArgumentError: Mailer template is missing\" with its source and environment."
            },
            %{
              "text" =>
                "If nothing arrives, test the key. `400` means the key is valid. `401` means it is not.",
              "code" =>
                "curl -s -o /dev/null -w \"%{http_code}\\n\" -X POST \"#{@ingest}/api/1/envelope/?sentry_key=$POSTDEPLOY_API_KEY\" \\\n  -H \"Content-Type: application/x-sentry-envelope\" -d 'test'",
              "filename" => "Terminal",
              "language" => "shell"
            }
          ]
        },
        %{
          "heading" => "Troubleshoot",
          "rows" => [
            %{
              "term" => "A crash is not captured",
              "detail" => "Attach the logger handler in `start/2` before the endpoint starts."
            },
            %{
              "term" => "The environment is not the one in your configuration",
              "detail" =>
                "The key sets the environment. Use a key from a source for that environment."
            },
            %{
              "term" => "Local tests post to production",
              "detail" =>
                "Set `dsn` only in the environments that report errors. A client without a DSN sends nothing."
            }
          ]
        },
        %{
          "heading" => "Existing postdeploy_sdk installs",
          "body" => [
            "Installs of `postdeploy_sdk` keep sending to the same key and host. Use `sentry` for new setups."
          ],
          "code" => """
          # lib/my_app/application.ex
          children = [
            {PostDeploy, []},
            MyAppWeb.Endpoint
          ]

          # lib/my_app_web/endpoint.ex, first plug
          plug PostDeploy.Plug
          """,
          "filename" => "application.ex",
          "language" => "elixir",
          "rows" => [
            %{
              "term" => "Configuration",
              "detail" =>
                "Set `POSTDEPLOY_API_KEY`. `POSTDEPLOY_ENVIRONMENT` and `POSTDEPLOY_RELEASE` are optional."
            },
            %{
              "term" => "Capture an error yourself",
              "detail" =>
                "Call `PostDeploy.capture_exception(exception, stacktrace: __STACKTRACE__)`."
            },
            %{
              "term" => "Request parameters are missing",
              "detail" =>
                "The plug does not attach parameters. Add filtered values with `PostDeploy.set_context(\"params\", ...)`."
            }
          ]
        }
      ],
      not_offered: [
        "The DSN holds a server secret. Do not put it in code that runs in a browser."
      ],
      related_paths: [
        %{"path" => "/docs/observe", "label" => "Choose a runtime and get a key"},
        %{"path" => "/docs/monitoring/heartbeats", "label" => "Heartbeat protocol reference"},
        %{"path" => "/error-tracking", "label" => "How Observe groups errors"}
      ]
    }
  end

  # -- Measure --------------------------------------------------------------

  defp analytics do
    %{
      slug: "docs-analytics",
      path: "/docs/analytics",
      primary_query: "install cookieless analytics script",
      title: "Install Measure and count a custom event | PostDeploy Docs",
      meta_description:
        "Create a Measure source for your hostname, add the script tag, register one custom event, and confirm the first pageview in PostDeploy.",
      nav_label: "Measure",
      summary: "Browser script, hostname allow list and custom events.",
      hero_heading: "Install Measure",
      hero_description:
        "Add one script tag to count pageviews without cookies, then push registered event names. Only the hostname you allow can send data.",
      code_verified_on: @verified,
      last_verified_on: @verified,
      body_sections: [
        %{
          "heading" => "Create a Measure source",
          "steps" => [
            %{
              "text" => "Ask your agent to create a source for the exact hostname of your site.",
              "code" =>
                "Create a Measure source named marketing site for the hostname www.example.com. Show me the browser token.",
              "filename" => "Prompt",
              "language" => "text"
            },
            %{
              "text" =>
                "Copy the token from the response. It starts with `msr_`. The token is public; the hostname allow list decides which pages can send data."
            }
          ]
        },
        %{
          "heading" => "Add the script",
          "body" => [
            "Place this before the closing body tag on every page. The script records the first pageview and later browser navigation."
          ],
          "code" => """
          <script>
            window.postdeployMeasure = window.postdeployMeasure || [];
          </script>
          <script
            defer
            src="#{@ingest}/m.js?token=YOUR_MEASURE_TOKEN&v=20260910"
          ></script>
          """,
          "filename" => "layout.html",
          "language" => "html"
        },
        %{
          "heading" => "Count a named action",
          "steps" => [
            %{
              "text" =>
                "Ask your agent to register the event name. Measure drops names that are not registered.",
              "code" => "Register the Measure event clicked_checkout for this project.",
              "filename" => "Prompt",
              "language" => "text"
            },
            %{
              "text" => "Push the name when the action succeeds.",
              "code" => """
              document.getElementById("checkout").addEventListener("click", function () {
                window.postdeployMeasure.push(["event", "clicked_checkout"]);
              });
              """,
              "filename" => "checkout.js",
              "language" => "javascript"
            }
          ],
          "after" => [
            "A name has 1 to 64 characters: lowercase letters, digits, `_` and `-`. Measure discards event properties."
          ]
        },
        %{
          "heading" => "Verify",
          "steps" => [
            %{"text" => "Load a page on the allowed hostname."},
            %{
              "text" =>
                "Open Measure. The title reads \"1 pageview in the last 24 hours\" and the current hour bar shows it in progress."
            }
          ]
        },
        %{
          "heading" => "Troubleshoot",
          "rows" => [
            %{
              "term" => "The network tab shows 204 and nothing is counted",
              "detail" =>
                "The page hostname is not allowed. `127.0.0.1` is not `localhost`. Ask your agent to allow the exact host, or `*.example.com` for subdomains."
            },
            %{
              "term" => "Pageviews count but events do not",
              "detail" =>
                "The event name is not registered. The server rejects it, and the page cannot see the response. Register the exact name."
            },
            %{
              "term" => "One browser sends nothing",
              "detail" => "The script does not send when Do Not Track is on. Test with it off."
            },
            %{
              "term" => "A script change does not reach visitors",
              "detail" =>
                "Browsers cache `m.js` for an hour. Change the `v=` value in the script URL."
            }
          ]
        }
      ],
      not_offered: [
        "Measure does not evaluate or display goals.",
        "Measure sets no cookies and keeps no visitor identifier across days, so it cannot report returning visitors."
      ],
      related_paths: [
        %{"path" => "/analytics", "label" => "How Measure counts visitors"},
        %{"path" => "/privacy", "label" => "What PostDeploy stores"},
        %{
          "path" => "/guides/why-analytics-tools-disagree",
          "label" => "Why analytics tools disagree"
        }
      ]
    }
  end

  # -- Product analytics -------------------------------------------------

  defp product_analytics do
    %{
      slug: "docs-product-analytics",
      path: "/docs/product-analytics",
      primary_query: "send product analytics events api",
      title: "Send product analytics events | PostDeploy Docs",
      meta_description:
        "Send behavioural events to PostDeploy over HTTP, then read funnels, activation and retention. One endpoint, one write-only key, any language.",
      nav_label: "Product analytics",
      summary: "The events API, batching, limits, retries and privacy.",
      hero_heading: "Send your first product event",
      hero_description:
        "One HTTP request tells PostDeploy what a person did in your application. From those events you get funnels, activation and retention, with no SDK to install.",
      code_verified_on: @verified,
      last_verified_on: @verified,
      body_sections: [
        %{
          "heading" => "Create a write key",
          "steps" => [
            %{
              "text" => "Ask your agent to create a product analytics source for this project.",
              "code" =>
                "Create a product analytics source named iOS app for the production environment. Show me the write key.",
              "filename" => "Prompt",
              "language" => "text"
            },
            %{
              "text" =>
                "Copy the key from the response. It starts with `pda_` and is shown once. It can write events into this one project and nothing else, so you can ship it inside a mobile or browser application."
            }
          ]
        },
        %{
          "heading" => "Send one event",
          "body" => [
            "Send the key as a bearer token. Only `event` is required."
          ],
          "code" => """
          curl #{@ingest}/v1/events \\
            -H "Authorization: Bearer pda_YOUR_WRITE_KEY" \\
            -H "Content-Type: application/json" \\
            -d '{
              "event": "onboarding_completed",
              "distinct_id": "anon_123",
              "properties": {
                "platform": "ios",
                "app_version": "1.4.0",
                "variant": "onboarding_b"
              }
            }'
          """,
          "filename" => "Terminal",
          "language" => "bash",
          "after" => [
            "PostDeploy answers `202` with `{\"success\": true, \"accepted\": 1}`. Open Analytics, then Live events, to watch it arrive."
          ]
        },
        %{
          "heading" => "Send a batch",
          "body" => [
            "Batch up to 100 events in one request. Send the whole batch or none of it: one invalid event refuses the request, so you always know what still needs sending."
          ],
          "code" => """
          curl #{@ingest}/v1/events/batch \\
            -H "Authorization: Bearer pda_YOUR_WRITE_KEY" \\
            -H "Content-Type: application/json" \\
            -d '{
              "events": [
                { "event": "onboarding_started", "distinct_id": "anon_123" },
                { "event": "onboarding_completed", "distinct_id": "anon_123" }
              ]
            }'
          """,
          "filename" => "Terminal",
          "language" => "bash"
        },
        %{
          "heading" => "JavaScript",
          "body" => [
            "Never block a person's interaction on analytics. Send it and move on."
          ],
          "code" => """
          function capture(event, distinctId, properties) {
            fetch("#{@ingest}/v1/events", {
              method: "POST",
              headers: {
                "Authorization": "Bearer " + PD_WRITE_KEY,
                "Content-Type": "application/json"
              },
              body: JSON.stringify({ event, distinct_id: distinctId, properties }),
              keepalive: true
            }).catch(() => {})
          }

          capture("paywall_viewed", anonId, { source: "onboarding" })
          """,
          "filename" => "analytics.js",
          "language" => "javascript"
        },
        %{
          "heading" => "Swift",
          "code" => """
          func capture(_ event: String, distinctId: String, properties: [String: Any] = [:]) {
              var request = URLRequest(url: URL(string: "#{@ingest}/v1/events")!)
              request.httpMethod = "POST"
              request.setValue("Bearer \\(writeKey)", forHTTPHeaderField: "Authorization")
              request.setValue("application/json", forHTTPHeaderField: "Content-Type")
              request.httpBody = try? JSONSerialization.data(withJSONObject: [
                  "event": event,
                  "distinct_id": distinctId,
                  "properties": properties
              ])

              URLSession.shared.dataTask(with: request).resume()
          }

          Task { capture("meal_logged", distinctId: anonId, properties: ["source": "camera"]) }
          """,
          "filename" => "Analytics.swift",
          "language" => "swift"
        },
        %{
          "heading" => "Kotlin",
          "code" => """
          suspend fun capture(event: String, distinctId: String, properties: Map<String, Any> = emptyMap()) {
              val payload = JSONObject(mapOf(
                  "event" to event,
                  "distinct_id" to distinctId,
                  "properties" to JSONObject(properties)
              )).toString()

              val request = Request.Builder()
                  .url("#{@ingest}/v1/events")
                  .header("Authorization", "Bearer $writeKey")
                  .post(payload.toRequestBody("application/json".toMediaType()))
                  .build()

              runCatching { client.newCall(request).execute().close() }
          }
          """,
          "filename" => "Analytics.kt",
          "language" => "kotlin"
        },
        %{
          "heading" => "Ruby",
          "code" => """
          def capture(event, distinct_id, properties = {})
            uri = URI("#{@ingest}/v1/events")
            request = Net::HTTP::Post.new(uri)
            request["Authorization"] = "Bearer \#{ENV.fetch("PD_WRITE_KEY")}"
            request["Content-Type"] = "application/json"
            request.body = JSON.generate(event: event, distinct_id: distinct_id, properties: properties)

            Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
          rescue StandardError
            nil
          end
          """,
          "filename" => "analytics.rb",
          "language" => "ruby"
        },
        %{
          "heading" => "Elixir",
          "code" => """
          def capture(event, distinct_id, properties \\\\ %{}) do
            Task.start(fn ->
              Req.post("#{@ingest}/v1/events",
                auth: {:bearer, System.fetch_env!("PD_WRITE_KEY")},
                json: %{event: event, distinct_id: distinct_id, properties: properties}
              )
            end)
          end
          """,
          "filename" => "analytics.ex",
          "language" => "elixir"
        },
        %{
          "heading" => "Several apps, one project",
          "body" => [
            "Keep the applications of one product in one project. Ask your agent for a write key per application: one for iOS, one for Android, one for your website. Each key rotates and revokes on its own.",
            "They share one event pool, which is the point. Send the same `distinct_id` from every application and a person who signs up on the web and acts in the app counts once in a funnel.",
            "Every screen then offers an App picker, and every MCP read takes an optional app, so you can look at one application alone or at all of them together."
          ],
          "code" =>
            "Create a product analytics source named Android app for the production environment. Show me the write key.",
          "filename" => "Prompt",
          "language" => "text"
        },
        %{
          "heading" => "What to track",
          "body" => [
            "Track meaningful state changes, not interface noise. `onboarding_completed`, `meal_logged`, `trial_started` and `subscription_started` each answer a product question. `button_clicked`, `modal_opened` and `screen_scrolled` do not, and they crowd out the events that do."
          ],
          "after" => [
            "Use the same name everywhere, in lower case with underscores. Put what varies in properties: `platform`, `app_version`, `variant`, `source`, `plan`, `country`."
          ]
        },
        %{
          "heading" => "Privacy",
          "body" => [
            "PostDeploy Analytics is designed for behavioural event data. Do not send sensitive personal information in event names, identifiers, or properties.",
            "That means no names, email addresses, phone numbers, precise addresses, message content, health information, photos, payment details or authentication tokens.",
            "`distinct_id` is whatever your application sends. Use an opaque identifier you generate. PostDeploy never derives an identity from an IP address, sets no cookie, fingerprints no device, and never joins one project's events to another's. The IP address of an ingest request is used to serve the request and is not stored on the event."
          ]
        },
        %{
          "heading" => "Limits",
          "rows" => [
            %{
              "term" => "Event name",
              "detail" => "1 to 120 characters: letters, digits, `_`, `.`, `:`, `-`."
            },
            %{
              "term" => "Distinct ID",
              "detail" => "Up to 200 characters. Optional, but unique-user counts need it."
            },
            %{
              "term" => "Properties",
              "detail" =>
                "Up to 40 per event. Names up to 64 characters, text values up to 512, 8 KB in total."
            },
            %{
              "term" => "Property values",
              "detail" => "Text, numbers, or true/false. Nested objects and lists are refused."
            },
            %{"term" => "Batch", "detail" => "Up to 100 events, 256 KB per request."},
            %{
              "term" => "Timestamp",
              "detail" =>
                "RFC 3339, within the last 30 days and not in the future. Defaults to arrival time."
            }
          ]
        },
        %{
          "heading" => "Retries and duplicates",
          "body" => [
            "Retry on `429`, on any `5xx`, and on a network failure, with exponential backoff. Honour `Retry-After` when it is present.",
            "Do not retry `400`, `401` or `403`: the request will not succeed until you change it.",
            "Send your own `id` on each event to make a retry safe. PostDeploy writes an event with an id it has already stored exactly once, so a retried batch does not inflate your counts. A repeated event still counts once against your monthly allowance."
          ],
          "code" => """
          {
            "id": "evt_0192f3c4d5e6",
            "event": "subscription_started",
            "distinct_id": "anon_123"
          }
          """,
          "filename" => "One event",
          "language" => "json"
        },
        %{
          "heading" => "Error responses",
          "rows" => [
            %{
              "term" => "`invalid_event`",
              "detail" => "400. The event name is missing or malformed."
            },
            %{
              "term" => "`invalid_payload`",
              "detail" => "400. The body is not the JSON shape this endpoint accepts."
            },
            %{
              "term" => "`invalid_properties`",
              "detail" => "400. A property name, value, or count is outside the limits."
            },
            %{
              "term" => "`invalid_timestamp`",
              "detail" => "400. The timestamp is malformed, too old, or in the future."
            },
            %{
              "term" => "`batch_too_large`",
              "detail" => "400. More than 100 events in one batch."
            },
            %{
              "term" => "`invalid_api_key`",
              "detail" =>
                "401. The key is missing, unknown, revoked, or not a product analytics key."
            },
            %{
              "term" => "`plan_inactive`",
              "detail" => "402. The organization has no active PostDeploy access."
            },
            %{"term" => "`body_too_large`", "detail" => "413. The request body is over 256 KB."},
            %{
              "term" => "`rate_limit_exceeded`",
              "detail" => "429. Back off and honour `Retry-After`."
            }
          ],
          "after" => [
            "Past your monthly allowance PostDeploy keeps answering `202` and reports what it dropped: `{\"accepted\": 0, \"dropped\": 1, \"dropped_reason\": \"quota\"}`. Your application never breaks because of an analytics limit."
          ]
        },
        %{
          "heading" => "If PostDeploy is unavailable",
          "body" => [
            "Analytics is best-effort client telemetry. Your application must keep working when PostDeploy does not answer, so never block a person's interaction on a capture call, and never raise from one."
          ]
        }
      ],
      faqs: [
        %{
          "question" => "How far back can I look?",
          "answer" =>
            "Events are kept for 90 days. Funnels, retention and unique-user counts all read those raw events, so they cannot look further back than that window."
        },
        %{
          "question" => "Does PostDeploy merge two distinct IDs?",
          "answer" =>
            "No. A distinct ID is counted exactly as your application sent it. Identity merging is not built, and nothing merges silently."
        },
        %{
          "question" => "Is it safe to put the write key in my app?",
          "answer" =>
            "Yes. A `pda_` key can write events into one project and do nothing else. It cannot read analytics, change project configuration, or reach monitors, incidents, billing or organization data. Rotate or revoke it through your agent at any time."
        }
      ]
    }
  end

  # -- MCP ------------------------------------------------------------------

  defp mcp do
    %{
      slug: "docs-mcp",
      path: "/docs/mcp",
      primary_query: "connect mcp client oauth",
      title: "Connect an MCP client with OAuth | PostDeploy Docs",
      meta_description:
        "Add the PostDeploy MCP server, approve one project and its permissions in the browser, and revoke a client when you are done.",
      nav_label: "MCP",
      summary: "OAuth connection, project consent, permissions and revocation.",
      hero_heading: "Connect an MCP client",
      hero_description:
        "Your agent connects with OAuth in the browser. You choose one project and the permissions it gets. There is no token to create or paste.",
      code_verified_on: @verified,
      last_verified_on: @verified,
      body_sections: [
        %{
          "heading" => "Add the server",
          "body" => [
            "Give your MCP client the endpoint. The \"Connect an agent\" screen of each project shows this prompt with the project name filled in."
          ],
          "code" =>
            "Set up a remote MCP server named \"my-project\" for this project.\nEndpoint: #{@mcp}\nAuthentication: OAuth.",
          "filename" => "Prompt",
          "language" => "text"
        },
        %{
          "heading" => "Approve access",
          "steps" => [
            %{
              "text" =>
                "The client opens \"Connect to PostDeploy\" in your browser. Sign in if asked."
            },
            %{
              "text" =>
                "Choose the organization, then the project. Only organizations where you are an owner or admin appear."
            },
            %{
              "text" =>
                "Under \"Choose access\", clear any permission the client does not need. At least one is required."
            },
            %{
              "text" =>
                "Select \"Allow access\". The browser returns to the client, and the project's \"Connect an agent\" screen shows \"Your agent is connected\"."
            }
          ]
        },
        %{
          "heading" => "Connect an agent that has no browser",
          "body" => [
            "An agent on a remote machine, in a container, or in CI cannot open a browser on its own host. Such a client uses the device flow instead. It prints a short code, and you approve on any device.",
            "The client posts to the device authorization endpoint, shows you the `user_code` and the verification address, then polls the token endpoint until you approve. Permissions and revocation work exactly as above."
          ],
          "code" =>
            "curl -s -X POST #{@issuer}/oauth/device_authorization \\\n  -d client_id=$CLIENT_ID \\\n  -d resource=#{@mcp} \\\n  -d scope='projects:read errors:read'",
          "filename" => "Terminal",
          "language" => "shell",
          "after" => [
            "Open #{@issuer}/activate, type the code, and choose the permissions. The client picks up its tokens on the next poll."
          ]
        },
        %{
          "heading" => "Permissions",
          "rows" => [
            %{"term" => "Projects", "detail" => "`projects:read`, `projects:write`"},
            %{"term" => "Monitor", "detail" => "`monitor:read`, `monitor:write`"},
            %{"term" => "Errors", "detail" => "`errors:read`, `errors:write`"},
            %{"term" => "Analytics", "detail" => "`analytics:read`, `analytics:write`"},
            %{"term" => "Changelog", "detail" => "`changelog:read`, `changelog:write`"},
            %{"term" => "Status and public pages", "detail" => "`status:read`, `status:write`"}
          ],
          "after" => [
            "A call outside the granted permissions fails with an insufficient scope error. Connect again to change them."
          ]
        },
        %{
          "heading" => "What your agent can do",
          "body" => [
            "The server exposes eight tools. `context.get` describes the project. `actions.search` and `actions.get` find product actions. `actions.read`, `actions.write`, `actions.publish` and `actions.destroy` run them by class, and `confirmations.get` reads an approval.",
            "With `projects:write` and an organization connection, your agent can also create a project, then set up its monitors, error source and analytics key in the same session. A connection pinned to one project cannot create another.",
            "Destructive actions, such as deleting an entry or revoking a key, wait for an owner or admin. Approve or reject them under \"Pending confirmations\" on the project's \"Connect an agent\" screen."
          ]
        },
        %{
          "heading" => "Revoke a client",
          "steps" => [
            %{"text" => "Open Organization Settings and find \"Connected MCP Clients\"."},
            %{
              "text" =>
                "Select \"Revoke\" on the client, type its name, and select \"Confirm revoke\". Its tokens stop working at once."
            }
          ]
        },
        %{
          "heading" => "For MCP client developers",
          "body" => [
            "An unauthenticated request to the endpoint returns `401` with a `WWW-Authenticate` header that points to the protected resource metadata. The authorization server supports client ID metadata documents and dynamic client registration, authorization code with S256 PKCE, and public clients without a secret."
          ],
          "code" =>
            "curl -s https://postdeploy.dev/.well-known/oauth-protected-resource/mcp\ncurl -s https://postdeploy.dev/.well-known/oauth-authorization-server",
          "filename" => "Terminal",
          "language" => "shell",
          "rows" => [
            %{
              "term" => "Access token",
              "detail" => "Starts with `mcoat_`, lasts 1 hour, sent as `Authorization: Bearer`."
            },
            %{
              "term" => "Refresh token",
              "detail" =>
                "Starts with `mcort_`, lasts 30 days, and rotates on every refresh. Store each new refresh token. If your client loses a token response, it can present the previous token again for 60 seconds and get a new pair. After that window, a used refresh token revokes the whole connection."
            },
            %{
              "term" => "Resource",
              "detail" => "Send `resource=#{@mcp}` exactly, on authorization and token requests."
            },
            %{
              "term" => "Revocation",
              "detail" =>
                "`POST https://postdeploy.dev/oauth/revoke` with the token. Revoking the refresh token also ends its access token."
            }
          ]
        },
        %{
          "heading" => "Troubleshoot",
          "rows" => [
            %{
              "term" => "Access stops after about an hour",
              "detail" =>
                "The client did not refresh. Reconnect, or update a client that does not refresh tokens."
            },
            %{
              "term" => "Every call returns 401 after a refresh",
              "detail" =>
                "A used refresh token was sent more than 30 seconds after it was replaced, which revokes the connection. Store each new refresh token, then connect again."
            },
            %{
              "term" => "The organization is missing on the consent screen",
              "detail" => "You are not an owner or admin there. Ask an owner to change your role."
            },
            %{
              "term" => "A delete never completes",
              "detail" =>
                "Destructive actions wait for approval. Open the project's \"Connect an agent\" screen and select \"Approve\"."
            },
            %{
              "term" => "The device flow answers `authorization_pending`",
              "detail" =>
                "Nobody approved the code yet. Keep polling at the advertised `interval`. A `slow_down` answer means you polled faster than that."
            }
          ]
        }
      ],
      not_offered: [
        "PostDeploy has no static MCP tokens. Every client connects through OAuth.",
        "An organization connection reaches every project in one organization. A project connection reaches one project. Connect again for another.",
        "Billing and subscription changes are not available through MCP."
      ],
      related_paths: [
        %{"path" => "/docs/mcp/changelog", "label" => "Publish a changelog entry through MCP"},
        %{"path" => "/docs/projects-and-keys", "label" => "Projects and keys"},
        %{"path" => "/docs/get-started", "label" => "Get your first signal"}
      ]
    }
  end

  defp mcp_changelog do
    %{
      slug: "docs-mcp-changelog",
      path: "/docs/mcp/changelog",
      primary_query: "publish changelog with mcp",
      title: "Publish a changelog entry through MCP | PostDeploy Docs",
      meta_description:
        "Draft, revise, preview and publish a PostDeploy changelog entry from your agent, then make the public changelog page live.",
      nav_label: "Changelog through MCP",
      summary: "Draft, revise, preview and publish changelog entries from an agent.",
      hero_heading: "Publish a changelog entry from your agent",
      hero_description:
        "Your agent drafts the entry, updates it in place, and publishes it. People review each entry, its state and its history in the dashboard.",
      code_verified_on: @verified,
      last_verified_on: @verified,
      body_sections: [
        %{
          "heading" => "Before you begin",
          "list" => [
            "A connected MCP client with `changelog:read` and `changelog:write`.",
            "`status:write` as well, if the project's public pages are not published yet."
          ]
        },
        %{
          "heading" => "Draft the entry",
          "body" => [
            "Use a stable `external_id`, such as a release name. Front matter sets the title, and optionally the summary, area and version."
          ],
          "code" => """
          {
            "name": "actions.write",
            "arguments": {
              "action": "changelog.upsert_draft",
              "idempotency_key": "release-2026-09-15-draft",
              "arguments": {
                "external_id": "release-2026-09-15",
                "markdown": "---\\ntitle: Heartbeat exit codes\\nsummary: Report a job result from its exit code.\\narea: monitor\\n---\\n\\nAdd `/h/TOKEN/$?` to the end of a crontab line.\\n",
                "sources": [{ "kind": "issue", "url": "https://github.com/example/app/issues/42", "label": "#42" }]
              }
            }
          }
          """,
          "filename" => "tools/call",
          "language" => "json"
        },
        %{
          "heading" => "Revise and preview",
          "body" => [
            "Send `changelog.upsert_draft` again with the same `external_id` to update the draft in place. Read the rendered result with `changelog.preview_entry`, and the history with `changelog.list_revisions`."
          ]
        },
        %{
          "heading" => "Publish",
          "body" => [
            "Pass the revision you reviewed. Publishing happens at once and needs no dashboard approval."
          ],
          "code" => """
          {
            "name": "actions.publish",
            "arguments": {
              "action": "changelog.publish_entry",
              "idempotency_key": "release-2026-09-15-publish",
              "arguments": { "entry_handle": "chg_...", "expected_revision": 1 }
            }
          }
          """,
          "filename" => "tools/call",
          "language" => "json",
          "after" => [
            "The public changelog page returns 404 until the project's public pages are published. Ask your agent to run `public.publish` once."
          ]
        },
        %{
          "heading" => "Where people step in",
          "list" => [
            "The Changelog entries screen lists every entry with its state. People review entries there; the agent edits and publishes them.",
            "Deleting an entry is destructive. It waits until an owner or admin selects \"Approve\" under \"Pending confirmations\".",
            "The dashboard has no button to write a new entry. Entries start with an agent."
          ]
        },
        %{
          "heading" => "Verify",
          "steps" => [
            %{
              "text" =>
                "Open the Changelog entries screen. The row \"Heartbeat exit codes\" shows Published."
            },
            %{"text" => "Open the project's public changelog page. It lists the entry."}
          ]
        },
        %{
          "heading" => "Troubleshoot",
          "rows" => [
            %{
              "term" => "`changelog.get_settings` returns not found",
              "detail" =>
                "The project has no changelog yet. The first `changelog.upsert_draft` creates it."
            },
            %{
              "term" => "The public changelog page returns 404",
              "detail" => "The public pages are not published. Run `public.publish` once."
            }
          ]
        }
      ],
      not_offered: [
        "Publishing needs no approval. Review the preview before your agent publishes.",
        "The dashboard does not create entries."
      ],
      related_paths: [
        %{"path" => "/docs/mcp", "label" => "Connect an MCP client"},
        %{"path" => "/changelog", "label" => "The PostDeploy changelog"}
      ]
    }
  end

  # -- Projects and keys ----------------------------------------------------

  defp projects_and_keys do
    %{
      slug: "docs-projects-and-keys",
      path: "/docs/projects-and-keys",
      primary_query: "postdeploy ingest key",
      title: "Projects and keys: rotation and revocation | PostDeploy Docs",
      meta_description:
        "Learn which PostDeploy keys belong to a project, which ones are secret, and how to rotate or revoke a key without losing events.",
      nav_label: "Projects and keys",
      summary: "Project boundaries, key types, rotation and revocation.",
      hero_heading: "Projects and keys",
      hero_description:
        "Every monitor, source and key belongs to one project. Your agent creates each key. Secret keys are shown once and rotate with a grace period.",
      code_verified_on: @verified,
      last_verified_on: @verified,
      body_sections: [
        %{
          "heading" => "How a project scopes data",
          "body" => [
            "An organization holds projects, members and the subscription. A project holds monitors, Observe and Measure sources, public pages and the changelog. An MCP connection reaches one project, so an agent cannot read or change a sibling project."
          ]
        },
        %{
          "heading" => "Key types",
          "rows" => [
            %{
              "term" => "Observe key, `obs_`",
              "detail" =>
                "Secret. Sends errors for one source and one environment. Keep it on the server."
            },
            %{
              "term" => "Heartbeat token, `hb_`",
              "detail" =>
                "Secret. Part of one monitor's heartbeat URL. Anyone with it can report a run."
            },
            %{
              "term" => "Measure token, `msr_`",
              "detail" =>
                "Public. Embedded in the page. The hostname allow list decides which pages can send data."
            },
            %{
              "term" => "MCP tokens, `mcoat_` and `mcort_`",
              "detail" =>
                "Issued to an MCP client through OAuth. You never copy them. Read [Connect an MCP client](/docs/mcp)."
            }
          ]
        },
        %{
          "heading" => "Create a key",
          "body" => [
            "Ask your connected agent. The response contains an `obs_` key or `hb_` token once, and later reads never return it. The dashboard shows only the first characters of an Observe key. A Measure token is public and can be read again."
          ],
          "code" =>
            "Create an Observe source named api for the staging environment. Show me the key.",
          "filename" => "Prompt",
          "language" => "text"
        },
        %{
          "heading" => "Rotate a key",
          "steps" => [
            %{
              "text" =>
                "Ask your agent to rotate the source with a grace period. The default is 24 hours and the maximum is 7 days.",
              "code" =>
                "Rotate the Observe key for the api source with a one hour grace period. Show me the new key.",
              "filename" => "Prompt",
              "language" => "text"
            },
            %{"text" => "Deploy the new key before the grace period ends."},
            %{
              "text" =>
                "After the grace period, the old key receives `401` with `invalid_api_key`."
            }
          ],
          "after" => [
            "A Measure token rotates with no grace period: the old token stops at once. Deploy the new snippet right after rotation. A heartbeat token is reissued instead, which needs approval."
          ]
        },
        %{
          "heading" => "Revoke a key",
          "body" => [
            "Revoking a source or reissuing a heartbeat token is destructive. The request waits under \"Pending confirmations\" on the project's \"Connect an agent\" screen until an owner or admin selects \"Approve\"."
          ]
        },
        %{
          "heading" => "Troubleshoot",
          "rows" => [
            %{
              "term" => "A key was lost",
              "detail" => "Rotate it and deploy the new key before the grace period ends."
            },
            %{
              "term" => "Events show the wrong environment",
              "detail" =>
                "The key sets the environment. Create a separate source for each environment."
            },
            %{
              "term" => "Requests with a key return 401",
              "detail" =>
                "The key is unknown, revoked, or past its grace period. Use the newest key."
            }
          ]
        }
      ],
      not_offered: [
        "The dashboard does not create or display full keys.",
        "Keys have no permission scopes. An Observe key sends data for its own source only."
      ],
      related_paths: [
        %{"path" => "/docs/observe", "label" => "Capture production errors"},
        %{"path" => "/docs/mcp", "label" => "Connect an MCP client"},
        %{"path" => "/privacy", "label" => "What PostDeploy stores"}
      ]
    }
  end
end
