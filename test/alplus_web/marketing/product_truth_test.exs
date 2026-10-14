defmodule AlplusWeb.Marketing.ProductTruthTest do
  @moduledoc """
  Guards the public marketing surface against claims the code does not
  support.

  `AlplusWeb.Marketing.ProductFacts` is the reviewed registry of what PostDeploy
  actually does. These tests check two directions:

  1. The registry agrees with the code that enforces the behaviour, so the
     registry cannot quietly rot into marketing fiction.
  2. The seeded public copy agrees with the registry, so a comparison page
     cannot claim a capability we do not ship, or deny one we do.

  A failure here means public copy and the product disagree. Fix whichever
  one is wrong; never relax the assertion to make it pass.
  """

  use Alplus.DataCase, async: true

  # For the llms.txt checks below: `get/2` and `response/2` are macros, and
  # the endpoint has to be named for a bare `build_conn/0` to be routable.
  import Phoenix.ConnTest

  @endpoint AlplusWeb.Endpoint

  alias Alplus.Billing.Package
  alias Alplus.Content
  alias Alplus.Measure.VisitorHash
  alias AlplusWeb.Marketing.ProductFacts

  describe "registry agrees with the enforcing code" do
    test "published check types match the monitor type CHECK constraint" do
      constraint_types =
        Alplus.Monitoring.Monitor
        |> monitor_type_constraint_sql()
        |> extract_quoted_values()

      assert Enum.sort(ProductFacts.facts()["monitor"]["check_types"]) ==
               Enum.sort(constraint_types)
    end

    test "published alert channels match the notification channel CHECK constraint" do
      channel_types =
        Alplus.Notifications.Channel
        |> channel_type_constraint_sql()
        |> extract_quoted_values()

      assert Enum.sort(ProductFacts.facts()["monitor"]["alert_channels"]) ==
               Enum.sort(channel_types)
    end

    test "heartbeat states match the states the ingest endpoint accepts" do
      states = ProductFacts.facts()["monitor"]["heartbeat_states"]

      # Every published state must be accepted by `Heartbeat.accept/2`'s guard.
      for state <- states do
        assert String.to_existing_atom(state) in [:start, :finish, :fail]
      end

      assert length(states) == 3
    end

    test "the privacy claims match what Measure actually persists" do
      privacy = ProductFacts.facts()["privacy"]

      assert privacy["stores_raw_ip"] == false
      assert privacy["cookies"] == false

      # The published claim is proven end to end by MeasureControllerTest, "no
      # raw referrer, IP, or user agent is ever persisted": it posts a secret
      # user agent and referrer through /m, then asserts neither reaches
      # analytics_dimensions.
      #
      # "Not reversible across days" rests on the salt rotating daily, which
      # VisitorHashTest proves by hashing identical inputs on two dates.
      today = ~U[2026-08-19 12:00:00Z]
      tomorrow = ~U[2026-08-20 12:00:00Z]
      ip = {203, 0, 113, 7}

      first = VisitorHash.hash("project", "source", ip, "UA", today)
      second = VisitorHash.hash("project", "source", ip, "UA", tomorrow)

      assert first != second, "the visitor hash must not be stable across days"
    end

    test "Measure does not claim goal conversions while ingest ignores goals" do
      facts = ProductFacts.facts()["measure"]

      assert facts["goal_conversions"] == false

      # Behaviour behind the claim: MeasureControllerTest, "rejects custom
      # events before quota or rollup writes", posts a custom_event through /m
      # and asserts a 400 with zero analytics rows written.
    end

    test "an SDK is only marked published when a reader could install it" do
      sdks = ProductFacts.facts()["sdks"]

      # Availability means "installable today", not "the source exists in our
      # monorepo". Each SDK is published on its listed registry.
      assert sdks["javascript"]["availability"] == "published"
      assert sdks["elixir"]["availability"] == "published"

      assert sdks["ruby"] == %{
               "package" => "postdeploy",
               "registry" => "rubygems",
               "availability" => "published"
             }

      for {_language, sdk} <- sdks do
        assert sdk["availability"] in ["published", "not_published"]
        assert is_binary(sdk["registry"])
      end
    end

    test "no public page tells a reader to install an unpublished SDK" do
      Content.Seeds.run()

      unpublished =
        ProductFacts.facts()["sdks"]
        |> Enum.filter(fn {_language, sdk} -> sdk["availability"] == "not_published" end)
        |> Enum.map(fn {_language, sdk} -> sdk["package"] end)

      for text <- all_public_text(), package <- unpublished do
        # e.g. `gem "alplus"`.
        refute text =~ ~r/\{:#{package},/
        refute text =~ ~r/gem ["']#{package}["']/
      end
    end
  end

  describe "seeded public copy agrees with the registry" do
    setup do
      Content.Seeds.run()
      :ok
    end

    test "no public page claims checks run on Cloudflare's network" do
      # Checks execute in the Phoenix app on a single AWS region
      # (`Alplus.Monitoring.HttpExecutor`), so a distributed-probe claim is
      # false wherever it appears.
      for text <- all_public_text() do
        refute text =~ ~r/checks? run from Cloudflare/i
      end
    end

    test "no public page claims goals are counted or offered" do
      for text <- all_public_text() do
        refute text =~ ~r/pageviews, custom events, goals/i
      end
    end

    test "no public page denies a check type the product ships" do
      shipped = ProductFacts.facts()["monitor"]["check_types"]
      assert "tcp" in shipped and "dns" in shipped

      # The old copy said Monitor did "HTTP checks and heartbeats, and
      # nothing else". That understates the product and must not return.
      for text <- all_public_text() do
        refute text =~ ~r/HTTP checks and heartbeats, and nothing else/i
        refute text =~ ~r/does HTTP checks from one path and nothing else/i
      end
    end

    test "Public pages are consistently described as live" do
      # Public pages are a project surface, not a package-counted resource.
      refute Map.has_key?(ProductFacts.facts()["package"]["limits"], "status_pages")

      refute Enum.any?(
               ProductFacts.facts()["product"]["not_offered"],
               &(&1["name"] == "Status pages")
             )
    end

    test "no public page claims Observe ingests logs" do
      # No log ingestion, log resource or log view exists, so logs are not
      # an offer.
      assert Enum.any?(
               ProductFacts.facts()["product"]["not_offered"],
               &(&1["name"] == "Logs")
             )

      # The home page's Observe bullet read "errors + logs" and promised one
      # stream of a stack trace plus "the logs around it". That copy was
      # false in both halves and must not return.
      for text <- all_public_text() do
        refute text =~ ~r/errors \+ logs/i
        refute text =~ ~r/logs around it/i
      end
    end

    test "the pricing page's allowances, prices and audience sizes come from the registry" do
      # The homepage became features-only (founder decision 2026-08-20), so
      # the allowance and price claims live on /pricing: the package card and
      # the pricing FAQ. Every figure must match the package.
      text = pricing_row_text()
      plan = Package.get()

      # The pricing page renders the package's allowances.
      html =
        Phoenix.ConnTest.build_conn()
        |> get("/pricing")
        |> response(200)

      assert html =~ "#{plan.limits.uptime_monitors} uptime and API monitors"
      assert html =~ "#{plan.limits.cron_jobs} cron and heartbeat jobs"

      # The pricing FAQ: the flat price straight from the registry.
      assert text =~ "$#{div(plan.price.amount_usd_cents, 100)} a month per organisation"

      for t <- all_public_text() do
        refute t =~ ~r/\b(Indie|Scale) plan\b|PostDeploy (Indie|Pro|Scale)\b/
        refute t =~ ~r/\b(one|the only) plan\b|\bPostDeploy plan\b/i
      end

      for t <- all_public_text() do
        refute t =~ ~r/founding/i
        refute t =~ ~r/normally \$\d+/i
      end
    end

    test "no public page claims a founder employment history" do
      # Founder decision (2026-08-19): the "production experience across
      # Heroku, AWS and Twilio" line was cut because nothing evidences it.
      # The founder appears in copy only as the single footer line and the
      # closing paragraph of /about, never as a claim about employers.
      for text <- all_public_text() do
        refute text =~ ~r/experience across Heroku/i
        refute text =~ ~r/worked at (Heroku|AWS|Amazon|Twilio)/i
      end
    end

    test "the homepage carries no meta copy about its own process" do
      # Product marketing v4 (2026-08-19): no public page may sell the
      # engineering hygiene instead of the product.
      text = home_row_text()

      refute text =~ ~r/plan registry/i
      refute text =~ ~r/product facts/i
      refute text =~ ~r/false claims/i
      refute text =~ ~r/no customers/i
      refute text =~ ~r/one engineer/i
      refute text =~ ~r/you can check/i
    end

    test "the homepage carries no waitlist or beta framing" do
      # Founder decision (2026-08-19): signup works and the site goes live
      # at DNS cutover, so waitlist framing was never accurate.
      text = home_row_text()

      refute text =~ ~r/waitlist/i
      refute text =~ ~r/private beta/i
      refute text =~ ~r/early access/i
    end
  end

  describe "the privacy page describes the running implementation" do
    setup do
      Content.Seeds.run()

      {:ok, privacy} = Content.get_guide_by_path("/privacy")
      %{text: privacy |> Map.from_struct() |> flatten_text()}
    end

    test "its retention numbers match the enforcing registry", %{text: text} do
      limits = Package.get().limits

      # Stated as prose on the page, so a registry change must not leave the
      # page quietly wrong. Numbers allow an optional thousands separator.
      assert text =~ "kept #{limits.detailed_uptime_retention_days} days"
      assert text =~ separated(limits.measure_retention_days)
      assert text =~ "Audit log entries are kept #{limits.audit_log_retention_days} days"
    end

    test "its privacy claims match the product-facts registry", %{text: text} do
      privacy = ProductFacts.facts()["privacy"]

      assert privacy["cookies"] == false
      assert privacy["stores_raw_ip"] == false
      assert text =~ ~r/sets no cookies/i
      assert text =~ ~r/discarded at (the point of )?ingest/i
    end

    test "it states the single checking region, matching Monitor", %{text: text} do
      assert ProductFacts.facts()["monitor"]["check_regions"] == 1
      assert text =~ ~r/single region/i
    end

    test "it makes no compliance claim the product cannot support", %{text: text} do
      # PostDeploy has no SOC 2, ISO certification or external pen test. The page
      # must say so rather than imply otherwise.
      assert text =~ ~r/no SOC 2/i

      refute text =~ ~r/(we are|AL\+ is) (SOC 2|ISO)[^.]*(certified|compliant)/i
      refute text =~ ~r/fully compliant/i
    end
  end

  describe "llms.txt agrees with the registry" do
    # The machine-readable surfaces must never contradict each other or the
    # HTML, because an AI system reading both gets to pick which to believe.

    setup do
      Content.Seeds.run()

      body =
        Phoenix.ConnTest.build_conn()
        |> get("/llms.txt")
        |> response(200)

      %{llms: body}
    end

    test "names every shipped check type", %{llms: llms} do
      for type <- ProductFacts.facts()["monitor"]["check_types"] do
        assert llms =~ ~r/#{type}/i, "llms.txt does not mention the #{type} check type"
      end
    end

    test "names what PostDeploy does not offer", %{llms: llms} do
      assert llms =~ ~r/ICMP/i
      assert llms =~ ~r/one region/i
    end

    test "states the privacy model the code implements", %{llms: llms} do
      assert llms =~ ~r/no cookies/i
      assert llms =~ ~r/no raw IP/i
    end

    test "states the package facts inline", %{llms: llms} do
      assert llms =~ "- #{Package.get().name}:"

      refute llms =~ "- Trial:"
      assert llms =~ "#{Package.trial_days()}-day free trial"
    end

    test "lists the monitoring cluster pages", %{llms: llms} do
      for path <- ["/monitoring", "/monitoring/cron-jobs", "/guides/github-actions-heartbeat"] do
        assert llms =~ path
      end
    end

    test "every linked page resolves", %{llms: llms} do
      paths =
        ~r{\]\(https://postdeploy\.dev(/[^)]*)\)}
        |> Regex.scan(llms, capture: :all_but_first)
        |> List.flatten()
        |> Enum.uniq()

      assert "/pricing" in paths
      assert "/product-facts.json" in paths

      for path <- paths do
        status = Phoenix.ConnTest.build_conn() |> get(path) |> Map.fetch!(:status)
        assert status == 200, "llms.txt links #{path}, which returns #{status}"
      end
    end
  end

  # -- helpers ----------------------------------------------------------

  # `1095` -> ~r/1,?095/, so prose may render a thousands separator without
  # the assertion caring, while a genuinely different number still fails.
  defp separated(number) do
    digits = Integer.to_string(number)

    if String.length(digits) > 3 do
      {lead, rest} = String.split_at(digits, String.length(digits) - 3)
      Regex.compile!("#{lead},?#{rest}")
    else
      Regex.compile!(digits)
    end
  end

  defp all_public_text do
    {:ok, pages} = Content.list_pages()
    {:ok, guides} = Content.list_guides()
    {:ok, comparisons} = Content.list_comparisons()

    Enum.map(pages ++ guides ++ comparisons, &(&1 |> Map.from_struct() |> flatten_text()))
  end

  # The `/` row's every string, concatenated, for homepage-scoped claims.
  defp home_row_text do
    {:ok, page} = Content.get_page_by_path("/")
    page |> Map.from_struct() |> flatten_text()
  end

  # The `/pricing` row's every string, concatenated, for pricing-scoped claims.
  defp pricing_row_text do
    {:ok, page} = Content.get_page_by_path("/pricing")
    page |> Map.from_struct() |> flatten_text()
  end

  # Every string anywhere in a content row, concatenated, so a claim is
  # caught wherever an author put it: body copy, a FAQ answer, a
  # comparison bullet, or a nested map value.
  defp flatten_text(value) when is_binary(value), do: value
  defp flatten_text(value) when is_list(value), do: Enum.map_join(value, " ", &flatten_text/1)

  defp flatten_text(%{} = value) do
    value |> Map.values() |> Enum.map_join(" ", &flatten_text/1)
  end

  defp flatten_text(_), do: ""

  defp monitor_type_constraint_sql(resource) do
    resource
    |> custom_statement_sql()
    |> Enum.find(&(&1 =~ "monitors_type_check"))
  end

  defp channel_type_constraint_sql(resource) do
    resource
    |> custom_statement_sql()
    |> Enum.find(&(&1 =~ "notification_channels_type_check"))
  end

  defp custom_statement_sql(resource) do
    resource
    |> AshPostgres.DataLayer.Info.custom_statements()
    |> Enum.map(& &1.up)
  end

  # Pulls `'http', 'keyword', ...` out of a `CHECK (col IN (...))` clause.
  defp extract_quoted_values(sql) do
    [_, list] = Regex.run(~r/IN \(([^)]*)\)/, sql)

    Regex.scan(~r/'([^']+)'/, list) |> Enum.map(fn [_, value] -> value end)
  end
end
