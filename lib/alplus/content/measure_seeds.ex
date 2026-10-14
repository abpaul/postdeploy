defmodule Alplus.Content.MeasureSeeds do
  @moduledoc """
  The Measure pillar hub, `/analytics` (SITE-ARCHITECTURE.md §6, W1, issue
  #52). The last of the three pillars to get a page — Monitor and Observe
  already have one — so it closes the "one toolkit, not three" positioning:
  every pillar now has somewhere to rank and link to.

  Seeded separately from `Alplus.Content.Seeds`, same reasoning as
  `ObserveSeeds` and `TrustSeeds`: one pillar per module keeps each
  readable. `Seeds.run/0` calls this one.

  Every capability claim is checked against the code by
  `AlplusWeb.Marketing.ProductTruthTest` and
  `AlplusWeb.Marketing.ProductFacts`. The trial analytics allowance is
  read from `Alplus.Billing.Package` at seed time, never typed as a literal,
  so a registry change cannot leave this page quietly wrong.
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

  defp guides, do: [analytics_hub()]

  # -- /analytics -----------------------------------------------------

  defp analytics_hub do
    formatted_analytics_events =
      PackagePresenter.thousands(Package.limit(:analytics_events_per_month))

    formatted_product_events =
      PackagePresenter.thousands(Package.limit(:product_events_per_month))

    %{
      slug: "analytics",
      path: "/analytics",
      cluster: "measure",
      intent: :commercial_investigation,
      primary_query: "privacy-first analytics",
      title: "Privacy-first analytics for small software teams | PostDeploy",
      meta_description:
        "Cookieless analytics: pageviews and custom events, with no raw IP storage or persistent visitor ID. Try it free for #{Package.trial_days()} days, no card required.",
      nav_label: "Analytics",
      summary:
        "The PostDeploy Measure pillar: pageviews and custom events without cookies, how visitors are counted with a daily-rotating salted hash instead of a stored identifier, what PostDeploy includes, and what Measure deliberately does not do.",
      hero_badge: "Web analytics and product analytics",
      hero_heading: "See how many people visit and what they do, with no cookies",
      hero_description:
        "Measure counts pageviews and custom events on your site. It sets no cookies, stores no raw IP address and keeps no persistent visitor identifier. Product analytics adds funnels, activation and retention from the events your app sends.",
      cta_heading: "Count your next visitor without a cookie",
      cta_label: "Start your #{Package.trial_days()}-day free trial",
      related_paths: [
        %{"path" => "/docs/analytics", "label" => "Install Measure and verify the first event"},
        %{"path" => "/pricing", "label" => "Pricing and limits"},
        %{"path" => "/privacy", "label" => "How PostDeploy handles your data"},
        %{
          "path" => "/guides/why-analytics-tools-disagree",
          "label" => "Guide: why analytics tools disagree about visitors"
        }
      ],
      lastmod: ~D[2026-09-10],
      body_sections: [
        %{
          "heading" => "Example setup",
          "transcript" => %{
            "project" => "my-saas",
            "prompt" => "Count visits to my-saas.com without cookies.",
            "actions" => [
              ["measure.create_source", "my-saas.com"]
            ],
            "result" => "Add the script tag it returns to your pages."
          }
        },
        %{
          "heading" => "What web analytics counts",
          "body" => [
            "Measure counts pageviews and the custom events you register. You see traffic and named actions rolled up per project, with no feed of individual visits."
          ]
        },
        %{
          "heading" => "Install Measure on your site",
          "body" => [
            "Ask your connected agent to run `measure.create_source` with a name, an environment and your site hostname. It returns a browser token.",
            "Replace `YOUR_MEASURE_TOKEN` with that token and add this before the closing body tag. The script records the first pageview and later browser navigation. Only the hostname you register can send data."
          ],
          "code" => """
          <script>
            window.postdeployMeasure = window.postdeployMeasure || [];
          </script>
          <script
            defer
            src="https://ingest.postdeploy.dev/m.js?token=YOUR_MEASURE_TOKEN&v=20260910"
          ></script>
          """,
          "filename" => "measure.html",
          "language" => "html",
          "copy" => true
        },
        %{
          "heading" => "Count a named action",
          "body" => [
            "Ask your agent to register the event name first, here `clicked_checkout`. Measure drops unregistered names and discards event properties.",
            "Then push the name when the action succeeds."
          ],
          "code" => ~s|window.postdeployMeasure.push(["event", "clicked_checkout"]);|,
          "filename" => "checkout.js",
          "language" => "javascript",
          "copy" => true
        },
        %{
          "heading" => "Keep visitor identity out of the data",
          "body" => [
            "Measure sets no cookies, stores no raw IP address, and keeps no persistent visitor identifier. It combines the project, source, IP address and user agent in a keyed hash. A secret salt rotates every day.",
            "Measure discards the raw inputs at ingest and stores only the hash. A hash from today cannot match a hash from yesterday, so Measure counts daily visitors and builds no long-term profile."
          ]
        },
        %{
          "heading" => "Add product analytics for what people do in your app",
          "body" => [
            "Your app sends events to PostDeploy over HTTP with a write-only `pda_` key. Each event has a name and an identifier your app generates. From those events you read funnels, activation and retention.",
            "Ask your agent to create a product analytics source for the project. The response returns the `pda_` key once. The key writes events into that one project and nothing else, so it can ship inside a browser or mobile app.",
            "Use an opaque identifier for `distinct_id`. Send no names, email addresses or other sensitive personal data. Events are kept for #{Package.limit(:product_event_retention_days)} days, and funnels and retention read only that window."
          ],
          "code" => """
          curl https://ingest.postdeploy.dev/v1/events \\
            -H "Authorization: Bearer pda_YOUR_WRITE_KEY" \\
            -H "Content-Type: application/json" \\
            -d '{"event": "onboarding_completed", "distinct_id": "anon_123"}'
          """,
          "filename" => "Terminal",
          "language" => "bash",
          "copy" => true
        },
        %{
          "heading" => "What analytics does not do",
          "body" => [
            "Web analytics counts pageviews and registered custom events, and goals are not evaluated or displayed.",
            "Product analytics counts a distinct ID exactly as your app sent it. It has no identity merging, no feature flags, no experiment engine, no autocapture and no attribution."
          ]
        },
        %{
          "heading" => "What the package includes",
          "body" => [
            "PostDeploy includes #{formatted_analytics_events} web analytics events and #{formatted_product_events} product analytics events a month, during the trial and after it for #{PackagePresenter.price()} a month.",
            "Web analytics and product analytics each have their own allowance. Read every limit on the pricing page, and the retention and data-handling rules on the privacy page."
          ]
        }
      ],
      faqs: [
        %{
          "q" => "Do I need a cookie banner for PostDeploy analytics?",
          "a" =>
            "PostDeploy sets no cookies, and Measure stores no persistent visitor identifier, so neither creates that requirement. Whether your site needs a banner depends on everything else running on it."
        },
        %{
          "q" => "Can PostDeploy tell me if a visitor came back next week?",
          "a" =>
            "Measure cannot. Its salt rotates daily, so a hash from one day never matches a hash from another. Product analytics can, because it reads the identifier your app sends."
        },
        %{
          "q" => "What identifier does product analytics use?",
          "a" =>
            "The `distinct_id` your app sends with each event. Generate an opaque value, such as a random ID stored in your own database or on the device."
        },
        %{
          "q" => "How many analytics events does PostDeploy include?",
          "a" =>
            "The #{Package.trial_days()}-day trial and the package include #{formatted_analytics_events} web analytics events and #{formatted_product_events} product analytics events a month, each on its own allowance."
        }
      ]
    }
  end
end
