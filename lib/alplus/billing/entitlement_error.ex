defmodule Alplus.Billing.EntitlementError do
  @moduledoc """
  The one caller-safe error shape for every package-aware decision.

  `Alplus.Billing.Access` returns this struct for every entitlement
  failure in every product: an atom `code` a caller can branch on, a
  human-readable `message`, and a `details` map for context. Billing
  resolves the organization's access itself; a caller never passes it.

  For an inactive organization, `reason` is `:plan_inactive` (the
  public wire code, `sdks/contract/protocol.md`), `cause`
  distinguishes `:trial_expired` from `:subscription_lapsed`, and
  `purge_date` carries the date stored data will be purged. Existing
  errors leave these three fields nil.
  """

  defexception [:code, :message, :details, :reason, :cause, :purge_date]

  @type t :: %__MODULE__{
          code: atom(),
          message: String.t(),
          details: map(),
          reason: atom() | nil,
          cause: atom() | nil,
          purge_date: Date.t() | nil
        }
end
