defmodule AlplusWeb.ProductFactsController do
  @moduledoc "Serves the public product facts contract as JSON."

  use AlplusWeb, :controller

  alias AlplusWeb.Marketing.ProductFacts

  def index(conn, _params), do: json(conn, ProductFacts.facts())
end
