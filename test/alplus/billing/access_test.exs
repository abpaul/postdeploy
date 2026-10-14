defmodule Alplus.Billing.AccessTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Billing.{Access, EntitlementError, Subscription}
  alias Alplus.Monitoring.Monitor
  alias Alplus.Repo
  alias Alplus.Scope

  defp project_scope(scope, project), do: Scope.put_project(scope, project.id)

  defp monitor_fixture(scope, org, project, type \\ "http") do
    Ash.create!(
      Monitor,
      %{
        org_id: org.id,
        project_id: project.id,
        type: type,
        name: "Monitor #{System.unique_integer([:positive])}"
      },
      action: :create,
      actor: project_scope(scope, project)
    )
  end

  describe "monitor gates from an org id alone" do
    test "enforces the package interval floor from the org id alone" do
      {org, scope} = org_fixture(scope_fixture())
      subscribe(org)
      project = project_fixture(scope, org)

      assert {:error,
              %EntitlementError{
                code: :interval_not_allowed,
                details: %{field: :interval_seconds, minimum_interval_seconds: 60}
              }} =
               Access.allow_monitor_create(org.id, %{
                 project_id: project.id,
                 type: "http",
                 interval_seconds: 30
               })

      assert {:ok, %{current: 0, limit: 100}} =
               Access.allow_monitor_create(org.id, %{
                 project_id: project.id,
                 type: "http",
                 interval_seconds: 60
               })
    end

    test "counts uptime monitors across the organisation and rejects cross-tenant projects" do
      {org, scope} = org_fixture(scope_fixture())
      subscribe(org)
      project = project_fixture(scope, org)

      limit = Alplus.Billing.Package.limit(:uptime_monitors)
      monitor_fixture(scope, org, project)

      assert {:ok, %{current: 1, limit: ^limit}} =
               Access.allow_monitor_create(org.id, %{
                 project_id: project.id,
                 type: "http",
                 interval_seconds: 60
               })

      # A cron job is counted on its own allowance, never as an uptime monitor.
      monitor_fixture(scope, org, project, "heartbeat")

      for _ <- 2..limit, do: monitor_fixture(scope, org, project)

      assert {:error,
              %EntitlementError{
                code: :monitor_limit_reached,
                details: %{metric: :uptime_monitors, current: ^limit, limit: ^limit}
              }} =
               Access.allow_monitor_create(org.id, %{
                 project_id: project.id,
                 type: "http",
                 interval_seconds: 60
               })

      {other_org, other_scope} = org_fixture(scope_fixture())
      other_project = project_fixture(other_scope, other_org)

      assert {:error, %EntitlementError{code: :project_not_found}} =
               Access.allow_monitor_create(org.id, %{
                 project_id: other_project.id,
                 type: "http",
                 interval_seconds: 300
               })
    end

    test "gates an interval-only update from the org id" do
      {org, _scope} = org_fixture(scope_fixture())
      subscribe(org)

      assert {:error, %EntitlementError{code: :interval_not_allowed}} =
               Access.allow_monitor_update(org.id, %{interval_seconds: 30})

      assert :ok = Access.allow_monitor_update(org.id, %{interval_seconds: 60})
    end
  end

  describe "access resolution" do
    test "an in-window trial resolves to trial" do
      {org, _scope} = org_fixture(scope_fixture())

      assert {:ok, :trial} = Access.check(org.id)
    end

    test "an expired trial is inactive and includes its purge date" do
      {org, _scope} = expired_trial_fixture(scope_fixture())

      assert {:error,
              %EntitlementError{
                code: :plan_inactive,
                reason: :plan_inactive,
                cause: :trial_expired,
                purge_date: %Date{}
              }} = Access.check(org.id)
    end

    test "active and past-due subscriptions resolve to subscribed" do
      {org, _scope} = org_fixture(scope_fixture())

      set_billing_status(org, "active")
      assert {:ok, :subscribed} = Access.check(org.id)

      set_billing_status(org, "past_due")
      assert {:ok, :subscribed} = Access.check(org.id)
    end

    test "a live mirrored subscription wins over a trialing organization status" do
      {org, _scope} = org_fixture(scope_fixture())
      record_subscription(org, :active)

      assert {:ok, :subscribed} = Access.check(org.id)
    end

    # Stripe can put a paid subscription into `trialing`. That is never a
    # second free trial: without a live mirrored subscription there is nothing
    # to grant, however far off `trial_ends_at` still is.
    test "a trialing status after a subscription existed does not grant a trial" do
      {org, _scope} = org_fixture(scope_fixture())
      # The subscription belongs to another Stripe environment, so the
      # environment-scoped read finds no row for this one.
      record_subscription(org, :canceled, "staging")
      set_billing_status(org, "trialing")

      assert {:error, %EntitlementError{code: :plan_inactive, cause: :subscription_lapsed}} =
               Access.check(org.id)
    end

    test "a canceled subscription is inactive and never restarts a trial" do
      {org, _scope} = org_fixture(scope_fixture())

      record_subscription(org, :canceled)
      set_billing_status(org, "canceled")

      assert {:error,
              %EntitlementError{
                code: :plan_inactive,
                cause: :subscription_lapsed,
                purge_date: ~D[2026-10-01],
                details: %{status: "canceled"}
              }} = Access.check(org.id)
    end
  end

  describe "one error shape for every entitlement failure" do
    test "an unknown organization is an EntitlementError" do
      assert {:error, %EntitlementError{code: :organization_not_found}} =
               Access.check("org_does_not_exist")

      assert {:error, %EntitlementError{code: :organization_not_found}} =
               Access.allow_create("org_does_not_exist", :projects)
    end

    test "capacity failures carry code, message, and details" do
      {org, owner_scope} = org_fixture(scope_fixture())
      subscribe(org)
      limit = Alplus.Billing.Package.limit(:projects)
      for _ <- 1..limit, do: project_fixture(owner_scope, org)

      assert {:error, %EntitlementError{code: :capacity_reached} = error} =
               Access.allow_create(org.id, :projects)

      assert is_binary(error.message)
      assert %{current: ^limit, limit: ^limit, metric: :projects} = error.details
    end
  end

  describe "invite-time seat reservation" do
    test "blocks an invitation when every seat is taken by members or pending invites" do
      {org, owner_scope} = org_fixture(scope_fixture())
      member = user_fixture()
      member_fixture(owner_scope, org, member)
      # Subscribe so the remaining invitations test seats, not access.
      subscribe(org)

      for _ <- 1..2 do
        Ash.create!(
          Alplus.Orgs.Invitation,
          %{org_id: org.id, email: unique_email(), role: "member"},
          action: :invite,
          actor: owner_scope
        )
      end

      # One seat remains after the owner, member, and two pending invitations.
      assert :ok = Access.allow_seat(org.id)

      email = unique_email()

      Ash.create!(
        Alplus.Orgs.Invitation,
        %{org_id: org.id, email: email, role: "member"},
        action: :invite,
        actor: owner_scope
      )

      assert {:error,
              %EntitlementError{code: :capacity_reached, details: %{current: 5, limit: 5}}} =
               Access.allow_seat(org.id)
    end
  end

  describe "notification channel gating" do
    test "allows every alert channel and rejects an unknown channel type" do
      {org, _scope} = org_fixture(scope_fixture())
      subscribe(org)

      assert :ok = Access.allow_notification_channel(org.id, "email")
      assert :ok = Access.allow_notification_channel(org.id, "webhook")

      assert {:error, %EntitlementError{code: :unknown_channel_type}} =
               Access.allow_notification_channel(org.id, "sms")
    end
  end

  defp subscribe(org), do: set_billing_status(org, "active")

  defp set_billing_status(org, billing_status) do
    Repo.query!(
      "UPDATE organizations SET plan_status = $1 WHERE id = $2",
      [billing_status, org.id]
    )
  end

  defp record_subscription(org, status, environment \\ "local") do
    Ash.create!(
      Subscription,
      %{
        org_id: org.id,
        stripe_environment: environment,
        stripe_subscription_id: "sub_#{status}_#{System.unique_integer([:positive])}",
        status: status,
        current_period_start: ~U[2026-08-01 00:00:00.000000Z],
        current_period_end: ~U[2026-09-01 00:00:00.000000Z]
      },
      action: :record,
      authorize?: false
    )
  end
end
