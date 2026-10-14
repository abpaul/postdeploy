defmodule Alplus.Secrets do
  @moduledoc """
  Resolves AshAuthentication token-signing secrets from application config.
  """

  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        Alplus.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:alplus, :token_signing_secret)
  end
end
