defmodule Alplus.Content.ObserveSeeds do
  @moduledoc """
  The Observe pillar hub, `/error-tracking` (SITE-ARCHITECTURE.md §6, W1).

  Monitor has a hub already; Observe and Measure do not, so two of three
  pillars cannot rank and the "one toolkit, not three" positioning has
  nothing to link to. This seeds the first of those two.

  Seeded separately from `Alplus.Content.Seeds` and
  `Alplus.Content.MonitoringSeeds`, same reasoning as `TrustSeeds`: one pillar
  per module keeps each readable. `Seeds.run/0` calls this one.

  Every capability claim is checked against the code by
  `AlplusWeb.Marketing.ProductTruthTest` and
  `AlplusWeb.Marketing.ProductFacts`. The trial error allowance is read
  from `Alplus.Billing.Package` at seed time, never typed as a literal, so a
  registry change cannot leave this page quietly wrong.
  """

  alias Alplus.Billing.Package
  alias Alplus.Content
  alias AlplusWeb.Marketing.PackagePresenter

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

  defp guides, do: [error_tracking_hub()]

  # -- /error-tracking -----------------------------------------------------

  defp error_tracking_hub do
    formatted_error_events =
      PackagePresenter.thousands(Package.limit(:error_events_per_month))

    %{
      slug: "error-tracking",
      path: "/error-tracking",
      cluster: "observe",
      intent: :commercial_investigation,
      primary_query: "error tracking",
      title: "Error tracking for small software teams | PostDeploy",
      meta_description:
        "Error tracking with grouping, releases and sourcemaps from PostDeploy Observe. Try it free for #{Package.trial_days()} days, no card required.",
      nav_label: "Error tracking",
      summary:
        "The PostDeploy Observe pillar: how errors are grouped and triaged, how releases and sourcemaps turn a minified stack trace back into your source, what PostDeploy includes, and what Observe deliberately does not do.",
      hero_badge: "Error tracking in the same project as uptime",
      hero_heading:
        "Production errors grouped into issues, with releases and readable stack traces",
      hero_description:
        "Observe catches unhandled errors in your app and groups matching ones into one issue with a running count. Each issue carries the release you tag. Upload a sourcemap and a minified stack trace reads like your source. Errors sit in the same project as your uptime checks and cron heartbeats.",
      cta_heading: "See the errors your users hit, grouped into issues",
      cta_label: "Start your #{Package.trial_days()}-day free trial",
      related_paths: [
        %{"path" => "/docs/observe", "label" => "Connect your Sentry client to PostDeploy"},
        %{"path" => "/pricing", "label" => "Pricing and limits"},
        %{
          "path" => "/analytics",
          "label" => "PostDeploy Measure also counts pageviews and custom events"
        },
        %{
          "path" => "/guides/investigate-errors-after-release",
          "label" => "Guide: investigate errors after a release"
        }
      ],
      lastmod: ~D[2026-10-12],
      body_sections: [
        %{
          "heading" => "Example setup",
          "transcript" => %{
            "project" => "my-saas",
            "prompt" => "Track errors for my-saas in production.",
            "actions" => [
              ["observe.create_source", "my-saas, production"]
            ],
            "result" =>
              "Use the key it returns in your Sentry client's DSN. Errors arrive grouped into issues."
          }
        },
        %{
          "heading" => "What PostDeploy Observe does",
          "body" => [
            "Observe turns a pile of stack traces into issues you can act on."
          ],
          "list" => [
            "Grouping and triage: errors with matching stack frames collapse into one issue with an event count. You mark each issue open, resolved or ignored.",
            "Releases: tag every deploy with a version. An issue shows the release it was recorded with, so you can investigate the deploy window.",
            "Sourcemap symbolication: upload the sourcemap from your build, and a stack trace from a minified bundle resolves to the original file, line and function name.",
            "Alerts: a new issue, a resolved issue that comes back, or an error spike can notify your alert channels."
          ]
        },
        %{
          "heading" => "Set up with your agent",
          "body" => [
            "Ask your connected agent to run `observe.create_source` with a name and an environment. The response returns an `obs_` key once.",
            "Store it as `POSTDEPLOY_API_KEY` in your server secrets. The key sets the environment, so create one source for each environment."
          ],
          "code" =>
            "Create an Observe source named api for the production environment. Show me the key.",
          "filename" => "Prompt",
          "language" => "text"
        },
        %{
          "heading" => "Point your Sentry client at PostDeploy",
          "body" => [
            "Use the Sentry client for your runtime in the app that reports errors. Set its DSN to your key at the PostDeploy ingest host. Unhandled exceptions and the errors you capture arrive as issues.",
            "Observe accepts Sentry clients for JavaScript on Node.js, Ruby and Elixir. Run the client in your server code."
          ],
          "code" => "SENTRY_DSN=https://obs_YOUR_KEY@ingest.postdeploy.dev/1",
          "filename" => "Server environment",
          "language" => "bash",
          "copy" => true
        },
        %{
          "heading" => "Upload a sourcemap with each release",
          "body" => [
            "Set the release to your version or commit SHA in your Sentry client. After each build, upload the sourcemap with one request and the same key."
          ],
          "code" => """
          curl -X POST "https://ingest.postdeploy.dev/e/artifacts?release=$VERSION&name=app.js.map" \\
            -H "Authorization: Bearer $POSTDEPLOY_API_KEY" \\
            -H "Content-Type: application/octet-stream" \\
            --data-binary @dist/app.js.map
          """,
          "filename" => "Terminal",
          "language" => "bash",
          "copy" => true
        },
        %{
          "heading" => "Errors and uptime in one project",
          "body" => [
            "An Observe source belongs to a project, next to that project's uptime checks, cron heartbeats and analytics. One login and one flat price cover all of them."
          ]
        },
        %{
          "heading" => "What PostDeploy Observe does not offer",
          "body" => [
            "Observe records errors. It does not ingest logs. It does not collect traces. It does not compute metrics. It does not record session replay."
          ]
        },
        %{
          "heading" => "How many errors PostDeploy includes",
          "body" => [
            "PostDeploy includes #{formatted_error_events} error events a month, during the trial and after it for #{PackagePresenter.price()} a month. Error events are kept for #{Package.limit(:error_event_retention_days)} days.",
            "Error events have their own allowance, separate from uptime and analytics. See the full set of limits on the pricing page."
          ]
        }
      ],
      faqs: [
        %{
          "q" => "How does PostDeploy decide two errors are the same issue?",
          "a" =>
            "By matching stack frames. Reports with the same signature collapse into one issue with a running event count, instead of one alert per occurrence."
        },
        %{
          "q" => "Which client sends errors to PostDeploy?",
          "a" =>
            "Use the Sentry client for your runtime. Set its DSN to your Observe key at the PostDeploy ingest host. JavaScript on Node.js, Ruby and Elixir have setup guides in the docs."
        },
        %{
          "q" => "Does the key go in my browser code?",
          "a" =>
            "No. The `obs_` key belongs in your server environment as `POSTDEPLOY_API_KEY`. PostDeploy shows it once, when your agent creates the source."
        },
        %{
          "q" => "How many error events does PostDeploy include?",
          "a" =>
            "The #{Package.trial_days()}-day trial and the package include #{formatted_error_events} a month, on their own allowance."
        }
      ]
    }
  end
end
