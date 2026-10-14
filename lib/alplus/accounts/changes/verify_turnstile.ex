defmodule Alplus.Accounts.Changes.VerifyTurnstile do
  @moduledoc """
  Verifies a Cloudflare Turnstile challenge response server-side
  (ARCHITECTURE.md §10). Applies to browser authentication actions only,
  never to ingest or machine routes.

  This is a `before_action` hook, not an `Ash.Resource.Validation`.
  A Turnstile token is single-use: Cloudflare's siteverify consumes
  it on the first check and returns `success: false` on any repeat.
  An `AshPhoenix.Form`-backed LiveView calls `Form.validate/2` on
  every `phx-change`, and Ash validations run on both `validate` and
  the real `submit`/action commit. Verifying as a validation spends
  the token on the first `phx-change` after the widget fills it in,
  so the real submit always sees an already-used token and fails.
  A `before_action` hook only runs when the action itself commits,
  so the token is checked exactly once.

  Usage: `change {Alplus.Accounts.Changes.VerifyTurnstile, argument: :turnstile_token}`
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidArgument

  @impl true
  def change(changeset, opts, _context) do
    argument = Keyword.fetch!(opts, :argument)

    Ash.Changeset.before_action(changeset, fn changeset ->
      token = Ash.Changeset.get_argument(changeset, argument)

      # Cloudflare's `remoteip` field is optional; we don't thread the
      # request IP through the changeset context to keep this check
      # decoupled from the web layer (ARCHITECTURE.md: business logic
      # lives in Ash, not plugs).
      case Alplus.Turnstile.Client.verify(token, nil) do
        {:ok, true} ->
          changeset

        {:ok, false} ->
          Ash.Changeset.add_error(
            changeset,
            InvalidArgument.exception(
              field: argument,
              message: "Verification failed. Please try again."
            )
          )

        {:error, _reason} ->
          Ash.Changeset.add_error(
            changeset,
            InvalidArgument.exception(
              field: argument,
              message: "Could not verify you're human right now. Try again shortly."
            )
          )
      end
    end)
  end
end
