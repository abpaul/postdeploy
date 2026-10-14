defmodule AlplusWeb.OAuthAuthorizationHTML do
  use AlplusWeb, :html

  embed_templates "oauth_authorization_html/*"

  @doc """
  The two-letter monogram shown in the consent header's client tile.

  The tile stands in for a client logo PostDeploy has no way to fetch, so
  it is decorative: the client's real name sits beside it in the heading,
  and the tile itself is `aria-hidden`.
  """
  def client_initials(client_name) do
    client_name
    |> String.trim()
    |> String.slice(0, 2)
    |> String.downcase()
  end
end
