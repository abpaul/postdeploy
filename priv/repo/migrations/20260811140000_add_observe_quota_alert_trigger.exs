defmodule Alplus.Repo.Migrations.AddObserveQuotaAlertTrigger do
  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    execute("""
    ALTER TABLE alert_rules
      ADD CONSTRAINT alert_rules_trigger_check_v2 CHECK (
        (module = 'observe' AND trigger_type IN ('new_issue', 'issue_regression', 'error_spike', 'quota')) OR
        (module = 'monitor' AND trigger_type IN ('check_down', 'check_recovered', 'ssl_expiring', 'domain_expiring'))
      ) NOT VALID
    """)

    execute("ALTER TABLE alert_rules VALIDATE CONSTRAINT alert_rules_trigger_check_v2")
    execute("ALTER TABLE alert_rules DROP CONSTRAINT alert_rules_trigger_check")

    execute(
      "ALTER TABLE alert_rules RENAME CONSTRAINT alert_rules_trigger_check_v2 TO alert_rules_trigger_check"
    )
  end

  def down do
    execute("SET lock_timeout = '3s'")
    execute("ALTER TABLE alert_rules DROP CONSTRAINT alert_rules_trigger_check")

    execute("""
    ALTER TABLE alert_rules
      ADD CONSTRAINT alert_rules_trigger_check CHECK (
        (module = 'observe' AND trigger_type IN ('new_issue', 'issue_regression', 'error_spike')) OR
        (module = 'monitor' AND trigger_type IN ('check_down', 'check_recovered', 'ssl_expiring', 'domain_expiring'))
      ) NOT VALID
    """)

    execute("ALTER TABLE alert_rules VALIDATE CONSTRAINT alert_rules_trigger_check")
  end
end
