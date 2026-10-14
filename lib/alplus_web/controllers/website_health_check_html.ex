defmodule AlplusWeb.WebsiteHealthCheckHTML do
  @moduledoc """
  The two handoff steps after a visitor asks the website health check for a
  monitor: confirm the draft, then the created monitor and its first check.

  The check itself is `AlplusWeb.WebsiteHealthCheckLive`.
  """

  use AlplusWeb, :html

  import AlplusWeb.MarketingComponents

  embed_templates "website_health_check_html/*"
end
