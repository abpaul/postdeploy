defmodule AlplusWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use AlplusWeb, :html

  import AlplusWeb.MarketingComponents

  embed_templates "error_html/*"

  # The default is to render a plain text page based on
  # the template name. For example, "500.html" becomes
  # "Internal Server Error". 404 has its own styled template above.
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
