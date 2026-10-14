defmodule AlplusWeb.BillingLiveTest do
  use AlplusWeb.ConnCase, async: true

  import Alplus.OrgsFixtures
  import Phoenix.LiveViewTest

  alias Alplus.Repo

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  test "shows the active trial without a local subscription", %{conn: conn} do
    user = user_fixture()
    {org, _scope} = org_fixture(Alplus.Scope.for_user(user.id))

    {:ok, view, _html} =
      conn
      |> log_in(user)
      |> live(~p"/dashboard/orgs/#{org.id}/billing")

    assert has_element?(view, "#billing-package", "PostDeploy trial")
    assert has_element?(view, "#billing-package-price", "no charge during the trial")
    assert has_element?(view, "#billing-trial-end")

    for feature <- Alplus.Billing.Package.get().features do
      assert has_element?(view, "#billing-included-#{feature.id}", feature.name)
    end

    refute has_element?(view, "#billing-summary", "plan")
  end

  test "returns 404 for another organization's billing page", %{conn: conn} do
    user = user_fixture()
    {_org, _scope} = org_fixture(Alplus.Scope.for_user(user.id))
    other_user = user_fixture()
    {other_org, _scope} = org_fixture(Alplus.Scope.for_user(other_user.id))

    assert_error_sent 404, fn ->
      conn
      |> log_in(user)
      |> live(~p"/dashboard/orgs/#{other_org.id}/billing")
    end
  end

  test "only the owner sees billing controls", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

    {:ok, owner_view, _html} =
      conn
      |> log_in(owner)
      |> live(~p"/dashboard/orgs/#{org.id}/billing")

    assert has_element?(owner_view, "#billing-owner-controls")
    assert has_element?(owner_view, "#billing-subscribe", "Subscribe for $29 a month")

    admin = user_fixture()
    _admin_scope = member_fixture(owner_scope, org, admin, "admin")

    {:ok, admin_view, _html} =
      conn
      |> log_in(admin)
      |> live(~p"/dashboard/orgs/#{org.id}/billing")

    refute has_element?(admin_view, "#billing-owner-controls")
    refute has_element?(admin_view, "#billing-subscribe")
  end

  test "the invoices portal link appears only once a subscription exists", %{conn: conn} do
    owner = user_fixture()
    {org, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(~p"/dashboard/orgs/#{org.id}/billing")

    # No subscription means no Stripe customer, so `create_portal/3` could only
    # fail — the control is hidden rather than offered.
    refute has_element?(view, "#billing-invoices-portal")

    Ash.create!(
      Alplus.Billing.Subscription,
      %{
        org_id: org.id,
        stripe_environment: "local",
        stripe_subscription_id: "sub_portal_gate",
        status: :active,
        current_period_start: ~U[2026-08-01 00:00:00.000000Z],
        current_period_end: ~U[2026-09-01 00:00:00.000000Z]
      },
      action: :record,
      authorize?: false
    )

    {:ok, subscribed_view, _html} =
      conn
      |> log_in(owner)
      |> live(~p"/dashboard/orgs/#{org.id}/billing")

    assert has_element?(subscribed_view, "#billing-invoices-portal", "Open billing portal")
  end

  test "shows a warning-toned usage meter for an org near its package limit", %{conn: conn} do
    owner = user_fixture()
    {org, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

    subscribed_fixture(org)

    period_start = Date.beginning_of_month(Date.utc_today())

    Alplus.Repo.query!(
      """
      INSERT INTO usage_periods
        (id, org_id, period_start, analytics_events, dropped_analytics_events, error_events, dropped_error_events, inserted_at, updated_at)
      VALUES ($1, $2, $3, 400000, 0, 0, 0, now(), now())
      """,
      [Alplus.Id.generate(:usage_period), org.id, period_start]
    )

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(~p"/dashboard/orgs/#{org.id}/billing")

    assert has_element?(view, "#usage-meter-analytics_events", "400K / 500K")

    html = render(view)
    assert html =~ ~r/usage-meter-analytics_events.*text-status-late-ink/s
  end

  test "admin can view usage meters and invoices but not billing controls", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    admin = user_fixture()
    _admin_scope = member_fixture(owner_scope, org, admin, "admin")

    {:ok, admin_view, _html} =
      conn
      |> log_in(admin)
      |> live(~p"/dashboard/orgs/#{org.id}/billing")

    assert has_element?(admin_view, "#usage-meter-projects")
    assert has_element?(admin_view, "#billing-invoices-empty")
    refute has_element?(admin_view, "#billing-owner-controls")
  end

  test "invoice empty state does not promise a portal without a subscription", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    admin = user_fixture()
    _admin_scope = member_fixture(owner_scope, org, admin, "admin")

    {:ok, view, _html} =
      conn
      |> log_in(admin)
      |> live(~p"/dashboard/orgs/#{org.id}/billing")

    assert has_element?(view, "#billing-invoices-empty", "after the first payment")
    refute has_element?(view, "#billing-invoices-empty", "billing portal")
  end

  test "invoice empty state does not promise a portal to a nonowner manager", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    admin = user_fixture()
    _admin_scope = member_fixture(owner_scope, org, admin, "admin")
    subscription_fixture(org, :active, ~U[2026-09-01 00:00:00.000000Z])

    {:ok, view, _html} =
      conn
      |> log_in(admin)
      |> live(~p"/dashboard/orgs/#{org.id}/billing")

    assert has_element?(view, "#billing-invoices-empty", "after the first payment")
    refute has_element?(view, "#billing-invoices-portal")
    refute has_element?(view, "#billing-invoices-empty", "billing portal")
  end

  test "renders a mirrored invoice with its amount, status, and date", %{conn: conn} do
    owner = user_fixture()
    {org, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

    invoice =
      Ash.create!(
        Alplus.Billing.Invoice,
        %{
          org_id: org.id,
          stripe_environment: "local",
          stripe_invoice_id: "in_live_test",
          amount_due: 1_900,
          amount_paid: 1_900,
          currency: "usd",
          status: :paid,
          invoice_pdf_url: "https://stripe.example/in_live_test.pdf",
          period_start: ~U[2026-08-01 00:00:00.000000Z],
          period_end: ~U[2026-09-01 00:00:00.000000Z]
        },
        action: :record,
        authorize?: false
      )

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(~p"/dashboard/orgs/#{org.id}/billing")

    refute has_element?(view, "#billing-invoices-empty")
    assert has_element?(view, "#invoice-#{invoice.id}", "19.00 USD")

    assert has_element?(
             view,
             "#invoice-#{invoice.id} a[href='https://stripe.example/in_live_test.pdf']"
           )
  end

  test "shows what is due, not what was paid, for a finalized-but-unpaid invoice", %{conn: conn} do
    owner = user_fixture()
    {org, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

    invoice =
      Ash.create!(
        Alplus.Billing.Invoice,
        %{
          org_id: org.id,
          stripe_environment: "local",
          stripe_invoice_id: "in_open_test",
          amount_due: 1_900,
          amount_paid: 0,
          currency: "usd",
          status: :open,
          period_start: ~U[2026-08-01 00:00:00.000000Z],
          period_end: ~U[2026-09-01 00:00:00.000000Z]
        },
        action: :record,
        authorize?: false
      )

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(~p"/dashboard/orgs/#{org.id}/billing")

    assert has_element?(view, "#invoice-#{invoice.id}", "19.00 USD")
    refute has_element?(view, "#invoice-#{invoice.id}", "0.00 USD")
  end

  test "only shows invoices mirrored in the current Stripe environment", %{conn: conn} do
    owner = user_fixture()
    {org, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

    local_invoice =
      Ash.create!(
        Alplus.Billing.Invoice,
        %{
          org_id: org.id,
          stripe_environment: "local",
          stripe_invoice_id: "in_shared_id",
          amount_due: 1_900,
          amount_paid: 1_900,
          currency: "usd",
          status: :paid,
          period_start: ~U[2026-08-01 00:00:00.000000Z],
          period_end: ~U[2026-09-01 00:00:00.000000Z]
        },
        action: :record,
        authorize?: false
      )

    staging_invoice =
      Ash.create!(
        Alplus.Billing.Invoice,
        %{
          org_id: org.id,
          stripe_environment: "staging",
          stripe_invoice_id: "in_shared_id",
          amount_due: 7_900,
          amount_paid: 7_900,
          currency: "usd",
          status: :paid,
          period_start: ~U[2026-08-01 00:00:00.000000Z],
          period_end: ~U[2026-09-01 00:00:00.000000Z]
        },
        action: :record,
        authorize?: false
      )

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(~p"/dashboard/orgs/#{org.id}/billing")

    assert has_element?(view, "#invoice-#{local_invoice.id}")
    refute has_element?(view, "#invoice-#{staging_invoice.id}")
  end

  test "shows the subscription and renewal from the current Stripe environment", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    Alplus.OrgsFixtures.subscribed_fixture(org)

    local_subscription = %{
      org_id: org.id,
      stripe_environment: "local",
      stripe_subscription_id: "sub_cadence_local",
      status: :active,
      current_period_start: ~U[2026-08-01 00:00:00.000000Z],
      current_period_end: ~U[2027-08-01 00:00:00.000000Z]
    }

    staging_subscription = %{
      local_subscription
      | stripe_environment: "staging",
        stripe_subscription_id: "sub_cadence_staging",
        current_period_end: ~U[2026-12-01 00:00:00.000000Z]
    }

    Ash.create!(Alplus.Billing.Subscription, local_subscription,
      action: :record,
      authorize?: false
    )

    Ash.create!(Alplus.Billing.Subscription, staging_subscription,
      action: :record,
      authorize?: false
    )

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(~p"/dashboard/orgs/#{org.id}/billing")

    assert has_element?(view, "#billing-package", "PostDeploy")
    assert has_element?(view, "#billing-period-end", "2027")
  end

  test "shows an active subscription's package, price, and monthly renewal", %{conn: conn} do
    owner = user_fixture()
    {org, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    Alplus.OrgsFixtures.subscribed_fixture(org)
    subscription_fixture(org, :active, ~U[2026-09-01 00:00:00.000000Z])

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(~p"/dashboard/orgs/#{org.id}/billing")

    assert has_element?(view, "#billing-status-badge", "Active")
    assert has_element?(view, "#billing-renewal", "2026")
    assert has_element?(view, "#billing-period-end", "Renews monthly")
    assert has_element?(view, "#billing-package-price", "$29")
    refute has_element?(view, "#billing-package", "trial")
    assert has_element?(view, "#billing-manage-subscription")
    refute has_element?(view, "#billing-subscribe")
  end

  test "shows a past-due subscription as actionable warning state", %{conn: conn} do
    owner = user_fixture()
    {org, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    Alplus.OrgsFixtures.subscribed_fixture(org)
    subscription_fixture(org, :past_due, ~U[2026-09-01 00:00:00.000000Z])

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(~p"/dashboard/orgs/#{org.id}/billing")

    assert has_element?(view, "#billing-status-badge", "Past due")
    assert has_element?(view, "#billing-status-badge .border-status-late-border")
    refute has_element?(view, "#billing-read-only")
  end

  test "shows canceled subscription, scheduled cancellation, read-only state, and purge date", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    Alplus.OrgsFixtures.subscribed_fixture(org)
    subscription_fixture(org, :canceled, ~U[2026-09-01 00:00:00.000000Z], true)

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(~p"/dashboard/orgs/#{org.id}/billing")

    assert has_element?(view, "#billing-status-badge", "Canceled")
    assert has_element?(view, "#billing-cancel-at-period-end", "Scheduled cancellation")
    assert has_element?(view, "#billing-scheduled-cancellation", "Ends")
    assert has_element?(view, "#billing-read-only", "Read only")
    assert has_element?(view, "#billing-purge-date", "Data purge date")
    assert has_element?(view, "#billing-subscribe")
  end

  test "shows an expired trial as read-only with its purge deadline", %{conn: conn} do
    owner = user_fixture()
    {org, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

    Repo.query!(
      "UPDATE organizations SET trial_ends_at = $1, plan_status = 'trialing' WHERE id = $2",
      [~U[2026-01-01 00:00:00.000000Z], org.id]
    )

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(~p"/dashboard/orgs/#{org.id}/billing")

    assert has_element?(view, "#billing-status-badge", "Trial expired")
    assert has_element?(view, "#billing-read-only", "Read only")
    assert has_element?(view, "#billing-purge-date", "2026")
  end

  test "renders the exact dropped count and 130 percent state", %{conn: conn} do
    owner = user_fixture()
    {org, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    Alplus.OrgsFixtures.subscribed_fixture(org)

    Repo.query!(
      """
      INSERT INTO usage_periods
        (id, org_id, period_start, analytics_events, dropped_analytics_events,
         error_events, dropped_error_events, inserted_at, updated_at)
      VALUES ($1, $2, $3, 650000, 7, 0, 0, now(), now())
      """,
      [Alplus.Id.generate(:usage_period), org.id, Date.beginning_of_month(Date.utc_today())]
    )

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(~p"/dashboard/orgs/#{org.id}/billing")

    assert has_element?(view, "#usage-meter-analytics_events", "650K / 500K")
    assert has_element?(view, "#usage-meter-analytics_events", "Events dropped")
    assert has_element?(view, "#usage-meter-analytics_events-drops", "Dropped events: 7")
    assert has_element?(view, "#usage-meter-analytics_events[data-usage-state=dropped]")
  end

  test "member cannot invoke any external billing event directly", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    member = user_fixture()
    _member_scope = member_fixture(owner_scope, org, member, "member")

    {:ok, view, _html} =
      conn
      |> log_in(member)
      |> live(~p"/dashboard/orgs/#{org.id}/billing")

    render_click(view, "checkout", %{})
    assert has_element?(view, "#flash-error", "Only the organization owner")

    render_click(view, "portal", %{})
    assert has_element?(view, "#flash-error", "Only the organization owner")
  end

  test "a stale owner session cannot invoke billing events after ownership transfers", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    new_owner = user_fixture()
    _new_owner_scope = member_fixture(owner_scope, org, new_owner, "admin")

    target_membership =
      Alplus.Orgs.list_memberships_for_org!(org.id, actor: owner_scope)
      |> Enum.find(&(&1.user_id == new_owner.id))

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(~p"/dashboard/orgs/#{org.id}/billing")

    Ash.update!(
      target_membership,
      %{},
      action: :promote_to_owner,
      actor: owner_scope
    )

    # The mounted view still has its old owner role in assigns. Each direct
    # event must rebuild the live owner scope before reaching a billing
    # boundary, so ownership transfer takes effect without a reconnect.
    render_click(view, "checkout", %{})
    assert has_element?(view, "#flash-error", "Only the organization owner")

    render_click(view, "portal", %{})
    assert has_element?(view, "#flash-error", "Only the organization owner")
  end

  test "a forged checkout event cannot buy a second subscription", %{conn: conn} do
    owner = user_fixture()
    {org, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    Alplus.OrgsFixtures.subscribed_fixture(org)
    subscription_fixture(org, :active, ~U[2026-09-01 00:00:00.000000Z])

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(~p"/dashboard/orgs/#{org.id}/billing")

    refute has_element?(view, "#billing-subscribe")
    render_click(view, "checkout", %{})

    assert has_element?(view, "#flash-error", "already has a subscription")
  end

  test "a trial organization subscribes through Checkout", %{conn: conn} do
    owner = user_fixture()
    {org, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(~p"/dashboard/orgs/#{org.id}/billing")

    view |> element("#billing-subscribe") |> render_click()

    assert_redirect(view, "https://checkout.stripe.test/session")
  end

  test "a plain member sees package usage but neither invoices nor billing controls", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    member = user_fixture()
    _member_scope = member_fixture(owner_scope, org, member, "member")

    {:ok, member_view, _html} =
      conn
      |> log_in(member)
      |> live(~p"/dashboard/orgs/#{org.id}/billing")

    assert has_element?(member_view, "#usage-meter-projects")
    assert has_element?(member_view, "#billing-package")
    refute has_element?(member_view, "#billing-invoices-empty")
    refute has_element?(member_view, "#billing-owner-controls")
  end

  test "an admin cannot begin Checkout by sending the event directly", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    admin = user_fixture()
    _admin_scope = member_fixture(owner_scope, org, admin, "admin")

    {:ok, view, _html} =
      conn
      |> log_in(admin)
      |> live(~p"/dashboard/orgs/#{org.id}/billing")

    render_click(view, "checkout", %{})

    assert has_element?(view, "#flash-error", "Only the organization owner")
  end

  test "an owner without a Stripe customer sees a portal error flash", %{conn: conn} do
    owner = user_fixture()
    {org, _scope} = org_fixture(Alplus.Scope.for_user(owner.id))

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(~p"/dashboard/orgs/#{org.id}/billing")

    render_click(view, "portal", %{})
    assert has_element?(view, "#flash-error", "No Stripe customer exists")
  end

  test "renders an unavailable meter with an actionable warning state" do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

    html =
      %{
        flash: %{},
        agent_connected?: false,
        org: org,
        organizations: [],
        nav_projects: [],
        scope: owner_scope,
        # The real LiveView renders the confirmation banner as a live
        # component. Keep this direct render focused on BillingLive's
        # unavailable meter markup, without mounting that unrelated component.
        current_user: nil,
        subscription: nil,
        invoices: [],
        usage_meters: [
          %{
            metric: :analytics_events,
            label: "Analytics events",
            used: nil,
            limit: nil,
            dropped: nil,
            status: :unavailable,
            state: :unavailable,
            tone: "warning"
          }
        ],
        billing_owner?: true,
        billing_viewer?: true,
        package: Alplus.Billing.Package.get(),
        on_trial?: true,
        trial_ends_at: org.trial_ends_at,
        billing_read_only?: false,
        billing_purge_at: nil,
        socket: %Phoenix.LiveView.Socket{transport_pid: self()}
      }
      |> AlplusWeb.BillingLive.render()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    assert html =~ ~s(id="usage-meter-analytics_events" data-usage-state="unavailable")
    assert html =~ "Unavailable"
    assert html =~ "border-status-late-border"
    refute html =~ "text-text-primary\">Unavailable"
  end

  defp subscription_fixture(
         org,
         status,
         period_end,
         cancel_at_period_end \\ false
       ) do
    Ash.create!(
      Alplus.Billing.Subscription,
      %{
        org_id: org.id,
        stripe_environment: "local",
        stripe_subscription_id: "sub_billing_state_#{System.unique_integer([:positive])}",
        status: status,
        current_period_start: ~U[2026-08-01 00:00:00.000000Z],
        current_period_end: period_end,
        cancel_at_period_end: cancel_at_period_end
      },
      action: :record,
      authorize?: false
    )
  end
end
