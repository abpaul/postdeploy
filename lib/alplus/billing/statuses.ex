defmodule Alplus.Billing.Statuses do
  @moduledoc """
  Closed status vocabularies for the local Billing mirror.

  The values here drive both Ash validations and the database CHECK
  constraints. Keep the migration drift test in sync when changing a list.
  """

  @subscription [
    # PostDeploy itself assigns `:trialing` on organization create, before any
    # Stripe subscription exists; Stripe supplies the other seven values.

    :active,
    :past_due,
    :canceled,
    :incomplete,
    :incomplete_expired,
    :paused,
    :trialing,
    :unpaid
  ]
  @invoice [:draft, :open, :paid, :uncollectible, :void]
  @webhook_event [:pending, :processing, :processed, :failed]

  @spec subscription() :: [atom()]
  def subscription, do: @subscription

  @spec invoice() :: [atom()]
  def invoice, do: @invoice

  @spec webhook_event() :: [atom()]
  def webhook_event, do: @webhook_event
end
