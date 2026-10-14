defmodule Alplus.Repo.Migrations.AddOrganizationPlanStatus do
  @moduledoc """
  Adds Stripe's subscription-status mirror to organizations.

  PostgreSQL 11+ stores this constant default in catalog metadata. Existing
  organizations read as `active` without a table rewrite, while new and old
  rolling application versions both receive the same non-null free-plan value.
  """

  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    execute("ALTER TABLE organizations ADD COLUMN plan_status text NOT NULL DEFAULT 'active'")

    execute("""
    ALTER TABLE organizations
      ADD CONSTRAINT organizations_plan_status_check
      CHECK (plan_status IN ('active', 'past_due', 'canceled', 'incomplete', 'incomplete_expired', 'paused', 'trialing', 'unpaid')) NOT VALID
    """)

    execute("ALTER TABLE organizations VALIDATE CONSTRAINT organizations_plan_status_check")
  end

  def down do
    execute("SET lock_timeout = '3s'")
    execute("ALTER TABLE organizations DROP CONSTRAINT organizations_plan_status_check")
    execute("ALTER TABLE organizations DROP COLUMN plan_status")
  end
end
