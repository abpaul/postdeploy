defmodule AlplusWeb.WebsiteHealthCheck.Page do
  @moduledoc """
  The one definition of the website health check's path, breadcrumb trail and
  SEO facts.

  Two renderers need them: `AlplusWeb.WebsiteHealthCheckLive` for the tool
  itself, and `AlplusWeb.WebsiteHealthCheckController` for the two handoff
  steps after a visitor asks for a monitor. A second copy of this trail would
  drift from the `BreadcrumbList` schema the page emits.
  """

  alias AlplusWeb.Marketing.Seo

  @path "/tools/website-health-check"
  @title "Website health check | PostDeploy"
  @description "Check whether a public URL responds, redirects, or has a certificate near expiry. One request from PostDeploy's current region."

  @spec path() :: String.t()
  def path, do: @path

  @spec breadcrumbs() :: [{String.t(), String.t()}]
  def breadcrumbs do
    [
      {"Home", "/"},
      {"Uptime monitoring", "/monitoring/uptime"},
      {"Website health check", @path}
    ]
  end

  @spec seo_opts() :: keyword()
  def seo_opts do
    [
      title: @title,
      description: @description,
      path: @path,
      json_ld: [Seo.breadcrumb_schema(breadcrumbs())]
    ]
  end
end
