defmodule Alplus.Accounts.Validations.SignupsEnabled do
  @moduledoc """
  Blocks account registration when `config :alplus, :signups_enabled?` is
  `false`. Read at request time (not compiled in) so the gate can be
  flipped without a deploy.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidChanges

  @impl true
  def validate(_changeset, _opts, _context) do
    if Application.get_env(:alplus, :signups_enabled?, true) do
      :ok
    else
      {:error, InvalidChanges.exception(message: "Sign-ups are currently disabled.")}
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: validate(changeset, opts, context)
end
