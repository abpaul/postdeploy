defmodule Alplus.Repo.Migrations.SinglePackageBillingState do
  @moduledoc """
  The expand step for the one package (`Alplus.Billing.Package`).

  With one package, `organizations.plan_id`, `subscriptions.plan_id` and
  `subscriptions.billing_interval` carry no information that
  `organizations.plan_status` and the subscription mirror do not already
  hold. This migration stops the application depending on them, and leaves
  every column in place (ARCHITECTURE.md §5, expand then contract).

  Why nothing is dropped or renamed here: migrations run on container boot
  while the previous release still serves traffic (`docs/PRODUCTION-CUTOVER.md`),
  and `kamal rollback` restores the previous image against the new schema.
  Dropping `plan_id` or renaming `plan_status` in this release would break
  every entitlement read in the release that is still serving, and would keep
  it broken after a rollback. A later release drops the three columns and
  renames `plan_status` to `billing_status`, once no serving release reads
  them.

  The new release keeps writing the legacy columns, so a rollback finds them
  populated. `subscriptions.plan_id` gains a default, because it is `NOT NULL`
  with no default and the mirror's upsert no longer names it.

  Two legacy combinations have no truthful meaning under one package, so this
  migration refuses to run while any such row exists and names the count:

  - `plan_id = 'trial'` with a non-trialing status. The new release reads it
    as a subscribed organization that never paid.
  - `plan_id = 'postdeploy'` with `plan_status = 'trialing'`. The new release
    reads it as a running trial for an organization that already bought the
    package.

  Resolve such rows by hand, then rerun. No customer or billing data is
  deleted or changed.
  """

  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    refuse_if_any(
      "organizations with plan_id 'trial' and a non-trialing status",
      "SELECT count(*) FROM organizations WHERE plan_id = 'trial' AND plan_status <> 'trialing'"
    )

    refuse_if_any(
      "organizations with plan_id 'postdeploy' and status 'trialing'",
      "SELECT count(*) FROM organizations WHERE plan_id = 'postdeploy' AND plan_status = 'trialing'"
    )

    execute("ALTER TABLE subscriptions ALTER COLUMN plan_id SET DEFAULT 'postdeploy'")
  end

  def down do
    execute("SET lock_timeout = '3s'")
    execute("ALTER TABLE subscriptions ALTER COLUMN plan_id DROP DEFAULT")
  end

  defp refuse_if_any(description, count_sql) do
    flush()

    case repo().query!(count_sql).rows do
      [[0]] ->
        :ok

      [[count]] ->
        raise "Refusing to migrate: #{count} #{description}. " <>
                "Resolve these rows by hand; see this migration's moduledoc."
    end
  end
end
