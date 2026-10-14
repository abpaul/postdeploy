defmodule AlplusWeb.NotificationSettingsLiveTest do
  use AlplusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Alplus.OrgsFixtures

  alias Alplus.Notifications.{AlertRule}

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp settings_path(org), do: ~p"/dashboard/orgs/#{org.id}/settings/notifications"

  test "an owner sees bounded empty states and can create a channel", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Acme"})
    subscribed_fixture(org)

    {:ok, view, html} = conn |> log_in(owner) |> live(settings_path(org))

    assert html =~ "Notification routing"
    assert has_element?(view, "#notification-channels-empty")
    assert has_element?(view, "#notification-rules-no-projects")
    assert has_element?(view, "#notification-deliveries-empty")

    render_submit(view, "submit_channel", %{
      "channel" => %{
        "name" => "Operations",
        "type" => "email",
        "is_default" => "true",
        "config" => %{"to" => "alerts-#{System.unique_integer()}@example.test"}
      }
    })

    assert has_element?(view, "#notification-channels-table")

    assert {:ok, channels} =
             Alplus.Notifications.list_channels_for_org(org.id, actor: owner_scope)

    assert [%{name: "Operations", is_default: true}] = channels
  end

  test "a member sees no notification configuration or delivery rows", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    member = user_fixture()
    member_fixture(owner_scope, org, member, "member")

    {:ok, view, html} = conn |> log_in(member) |> live(settings_path(org))

    assert html =~ "Only owners and administrators can manage notification routing"
    assert has_element?(view, "#notification-settings-permission")
    refute has_element?(view, "#notification-channels")
    refute has_element?(view, "#notification-rules")
    refute has_element?(view, "#notification-deliveries")
  end

  test "a demoted live session loses management controls at its next event", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    subscribed_fixture(org)

    {:ok, _channel} =
      Alplus.Notifications.create_channel(
        %{
          org_id: org.id,
          type: "email",
          name: "Operations",
          config: %{"to" => "ops@example.test"}
        },
        owner_scope
      )

    {:ok, view, _html} = conn |> log_in(owner) |> live(settings_path(org))
    assert has_element?(view, "#notification-channels")

    Alplus.Repo.query!(
      "UPDATE memberships SET role = 'member' WHERE org_id = $1 AND user_id = $2",
      [org.id, owner.id]
    )

    html = render_click(view, "reload_deliveries")
    assert html =~ "Your organization role no longer permits notification management."
    refute has_element?(view, "#notification-channels")
    refute has_element?(view, "#notification-deliveries")

    render_click(view, "new_channel")
    refute has_element?(view, "#notification-channel-form")
  end

  test "channel destinations stay masked after editing", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    subscribed_fixture(org)

    {:ok, channel} =
      Alplus.Notifications.create_channel(
        %{
          org_id: org.id,
          type: "email",
          name: "Operations",
          config: %{"to" => "private-#{System.unique_integer()}@example.test"},
          is_default: true
        },
        owner_scope
      )

    {:ok, view, html} = conn |> log_in(owner) |> live(settings_path(org))

    assert html =~ "p•••@example.test"
    refute html =~ "private-"

    render_click(view, "edit_channel", %{"id" => channel.id})
    edited_html = render(view)
    refute edited_html =~ "private-"
    assert edited_html =~ "Replacement values are required"
    assert has_element?(view, "#notification-channel-default[checked]")

    replacement = "replacement-#{System.unique_integer([:positive])}@example.test"

    render_submit(view, "submit_channel", %{
      "channel" => %{
        "name" => "Operations replacement",
        "type" => "email",
        "is_default" => "false",
        "config" => %{"to" => replacement}
      }
    })

    assert {:ok, [presentation]} =
             Alplus.Notifications.list_channel_presentations(owner_scope)

    assert presentation.name == "Operations replacement"
    refute render(view) =~ replacement
    refute inspect(presentation) =~ replacement
  end

  test "an owner creates, disables, and edits a project-scoped rule", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    subscribed_fixture(org)
    project = project_fixture(owner_scope, org, %{name: "Payments"})

    {:ok, channel} =
      Alplus.Notifications.create_channel(
        %{
          org_id: org.id,
          type: "email",
          name: "Operations",
          config: %{"to" => "ops@example.test"}
        },
        owner_scope
      )

    {:ok, view, _html} = conn |> log_in(owner) |> live(settings_path(org))

    render_submit(view, "submit_rule", %{
      "rule" => %{
        "project_id" => project.id,
        "module" => "monitor",
        "trigger_type" => "check_down",
        "channel_id" => channel.id,
        "enabled" => "true",
        "condition" => %{"threshold" => "3"}
      }
    })

    assert has_element?(view, "#notification-rules-table")
    rule = Ash.read_one!(AlertRule, actor: Alplus.Scope.put_project(owner_scope, project.id))
    render_click(view, "toggle_rule", %{"id" => rule.id, "project-id" => project.id})

    assert %{enabled: false} =
             Ash.get!(AlertRule, rule.id,
               actor: Alplus.Scope.put_project(owner_scope, project.id)
             )

    render_click(view, "edit_rule", %{"id" => rule.id, "project-id" => project.id})
    assert render(view) =~ "Save rule"

    render_submit(view, "submit_rule", %{
      "rule" => %{
        "project_id" => project.id,
        "module" => "monitor",
        "trigger_type" => "check_recovered",
        "channel_id" => channel.id,
        "enabled" => "false",
        "condition" => %{"threshold" => "5"}
      }
    })

    assert %{trigger_type: "check_recovered", enabled: false} =
             Ash.get!(AlertRule, rule.id,
               actor: Alplus.Scope.put_project(owner_scope, project.id)
             )
  end

  test "rules and channels stay inside the selected organization", %{conn: conn} do
    owner = user_fixture()
    {org_a, scope_a} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Org A"})
    {org_b, scope_b} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Org B"})
    subscribed_fixture(org_a)
    subscribed_fixture(org_b)
    project_a = project_fixture(scope_a, org_a, %{name: "Project A"})
    project_b = project_fixture(scope_b, org_b, %{name: "Project B"})

    {:ok, channel_a} =
      Alplus.Notifications.create_channel(
        %{
          org_id: org_a.id,
          type: "email",
          name: "A channel",
          config: %{"to" => "a@example.test"}
        },
        scope_a
      )

    {:ok, channel_b} =
      Alplus.Notifications.create_channel(
        %{
          org_id: org_b.id,
          type: "email",
          name: "B channel",
          config: %{"to" => "b@example.test"}
        },
        scope_b
      )

    Ash.create!(
      AlertRule,
      %{
        org_id: org_a.id,
        project_id: project_a.id,
        module: "monitor",
        trigger_type: "check_down",
        channel_id: channel_a.id
      },
      action: :create,
      actor: Alplus.Scope.put_project(scope_a, project_a.id)
    )

    Ash.create!(
      AlertRule,
      %{
        org_id: org_b.id,
        project_id: project_b.id,
        module: "monitor",
        trigger_type: "check_down",
        channel_id: channel_b.id
      },
      action: :create,
      actor: Alplus.Scope.put_project(scope_b, project_b.id)
    )

    {:ok, view, html} = conn |> log_in(owner) |> live(settings_path(org_a))

    assert html =~ "A channel"
    assert html =~ "Project A"
    refute html =~ "B channel"
    refute html =~ "Project B"
    refute has_element?(view, "#notification-channel-b")
  end
end
