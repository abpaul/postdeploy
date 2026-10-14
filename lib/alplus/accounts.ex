defmodule Alplus.Accounts do
  @moduledoc """
  Ash domain for users and their authentication tokens.
  """

  use Ash.Domain,
    otp_app: :alplus

  resources do
    resource Alplus.Accounts.Token
    resource Alplus.Accounts.User
  end
end
