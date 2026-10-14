defmodule Alplus.Accounts.Actions.RequestPasswordReset do
  @moduledoc false

  use Ash.Resource.Actions.Implementation

  alias Ash.Error.Changes.InvalidArgument

  @impl true
  def run(action_input, opts, context) do
    token = Ash.ActionInput.get_argument(action_input, :turnstile_token)

    case Alplus.Turnstile.Client.verify(token, nil) do
      {:ok, true} ->
        AshAuthentication.Strategy.Password.RequestPasswordReset.run(action_input, opts, context)

      {:ok, false} ->
        {:error,
         InvalidArgument.exception(
           field: :turnstile_token,
           message: "Verification failed. Please try again."
         )}

      {:error, _reason} ->
        {:error,
         InvalidArgument.exception(
           field: :turnstile_token,
           message: "Could not verify you're human right now. Try again shortly."
         )}
    end
  end
end
