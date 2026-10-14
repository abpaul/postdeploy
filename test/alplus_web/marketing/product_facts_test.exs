defmodule AlplusWeb.Marketing.ProductFactsTest do
  use ExUnit.Case, async: true

  alias Alplus.Billing.Package
  alias AlplusWeb.Marketing.ProductFacts

  test "publishes the one package with its enforced price, limits, features and exclusions" do
    facts = ProductFacts.facts()
    package = Package.get()
    published = facts["package"]

    refute Map.has_key?(facts, "plans")
    assert published["id"] == "postdeploy"
    assert published["billed_per"] == "organization"

    assert published["pricing"] == %{
             "currency" => "USD",
             "billing_period" => "month",
             "price_usd_cents" => package.price.amount_usd_cents,
             "tax" => "exclusive"
           }

    assert published["limits"]["uptime_monitors"] == package.limits.uptime_monitors
    assert published["limits"]["cron_jobs"] == package.limits.cron_jobs
    refute Map.has_key?(published["limits"], "goals_per_project")

    assert Enum.map(published["features"], & &1["id"]) ==
             Enum.map(package.features, &Atom.to_string(&1.id))

    assert published["not_included"] == package.not_included

    assert facts["lifecycle"] == %{
             "trial" => %{
               "days" => Package.trial_days(),
               "card_required" => false,
               "limits" => "package",
               "data_retention_after_expiry_days" => Package.inactive_retention_days()
             }
           }
  end

  test "records the release stage and every excluded capability" do
    product = ProductFacts.facts()["product"]

    assert product["release_stage"] == "generally_available"
    assert Enum.all?(product["pillars"], &(&1["availability"] == "live"))
    assert Enum.map(product["not_offered"], & &1["name"]) == ["Goal tracking", "Logs"]
  end

  test "renders the one package as Markdown from the enforced package" do
    markdown = ProductFacts.pricing_markdown()

    assert markdown =~ "Contract version: #{ProductFacts.version()}"
    assert markdown =~ "### PostDeploy"
    assert markdown =~ "* Price: $#{div(Package.price_usd_cents(), 100)}/month"
    refute markdown =~ "### Trial"
    refute markdown =~ "/year"
    assert markdown =~ "Uptime and API monitors: #{Package.limit(:uptime_monitors)}"
    assert markdown =~ "* Not included: #{Enum.join(Package.get().not_included, ", ")}"
  end
end
