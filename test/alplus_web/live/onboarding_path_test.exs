defmodule AlplusWeb.OnboardingPathTest do
  @moduledoc """
  Phase 2 "Done when" (BUILD.md §6): register -> verify email -> create org
  -> create project -> archive project, driven through the real LiveView and
  controller pipeline (no direct Ash calls standing in for a step a browser
  would take).
  """

  use AlplusWeb.ConnCase, async: false
  use Oban.Testing, repo: Alplus.Repo

  import Phoenix.LiveViewTest

  require Ash.Query

  alias Alplus.Mailer.Worker
  alias Alplus.Projects.Project

  test "register, confirm through the emailed token, create org, create project, archive project",
       %{conn: conn} do
    email = "onboarding-#{System.unique_integer([:positive])}@example.com"

    {:ok, register_view, _html} = live(conn, ~p"/register")

    html =
      render_submit(register_view, "save", %{
        "user" => %{
          "email" => email,
          "password" => "a-str0ng-passphrase",
          "password_confirmation" => "a-str0ng-passphrase",
          "turnstile_token" => "widget-token"
        }
      })

    %{rows: [[user_id]]} =
      Alplus.Repo.query!("SELECT id FROM users WHERE email = $1", [email])

    assert [%{args: mail_args}] =
             all_enqueued(
               worker: Worker,
               args: %{"purpose" => "user_confirmation", "user_id" => user_id}
             )

    assert :ok = perform_job(Worker, mail_args)
    assert_received {:email, sent_email}
    assert Enum.map(sent_email.to, fn {_name, address} -> address end) == [email]

    # Auto-sign-in establishes a real session before email confirmation, but
    # unverified users intentionally land at the dashboard verification gate
    # rather than being allowed into organization setup.
    auto_signin_token = extract_auto_signin_token(html)
    conn = post(conn, ~p"/register/complete", %{"token" => auto_signin_token})
    assert redirected_to(conn) == ~p"/dashboard"
    refute conn.assigns.current_user.confirmed_at

    {:ok, dashboard_view, _html} = live(conn, ~p"/dashboard")
    assert has_element?(dashboard_view, "#activation-email-verification")

    # The emailed confirm link still works independently of that session,
    # confirming the same user.
    confirm_token = extract_confirm_token(sent_email.html_body)
    {:ok, confirm_view, _html} = live(conn, "/confirm_new_user/#{confirm_token}")

    confirm_form = form(confirm_view, "form")
    assert render_submit(confirm_form) =~ "phx-trigger-action"

    conn = follow_trigger_action(confirm_form, conn)
    assert redirected_to(conn) == ~p"/dashboard/orgs/new"
    assert conn.assigns.current_user.confirmed_at

    {:ok, org_view, _html} = live(conn, redirected_to(conn))

    org_view
    |> form("#new-org-form", organization: %{name: "Launchpad Org"})
    |> render_submit()

    assert %Alplus.Orgs.Organization{public_token: public_token} =
             Ash.read_one!(
               Ash.Query.filter(Alplus.Orgs.Organization, name == "Launchpad Org"),
               authorize?: false
             )

    assert_redirect(org_view, ~p"/dashboard/orgs/#{public_token}/projects")

    {:ok, projects_view, _html} = live(conn, ~p"/dashboard/orgs/#{public_token}/projects")

    projects_view
    |> form("#first-project-form", project: %{name: "First Project"})
    |> render_submit()

    assert %Project{id: project_id, public_token: project_token} =
             Ash.read_one!(
               Ash.Query.filter(Project, name == "First Project"),
               authorize?: false
             )

    assert_redirect(
      projects_view,
      ~p"/dashboard/orgs/#{public_token}/projects/#{project_token}/connect"
    )

    {:ok, projects_view, _html} = live(conn, ~p"/dashboard/orgs/#{public_token}/projects")

    assert has_element?(projects_view, "#project-name-#{project_id}", "First Project")

    projects_view
    |> element("#archive-project-#{project_id}-trigger")
    |> render_click()

    render_change(projects_view, "archive_input", %{
      "id" => project_id,
      "confirm_text" => "First Project"
    })

    projects_view
    |> form("#archive-project-#{project_id}-form", %{
      "id" => project_id,
      "confirm_text" => "First Project"
    })
    |> render_submit()

    refute has_element?(projects_view, "#project-name-#{project_id}")

    archived_row = Alplus.Repo.get(Project, project_id)
    assert archived_row.archived_at
  end

  defp extract_confirm_token(html_body) do
    [_, token] = Regex.run(~r{/confirm_new_user/([^"\s]+)}, html_body)
    token
  end

  defp extract_auto_signin_token(html) do
    [_, token] = Regex.run(~r{name="token" value="([^"]+)"}, html)
    token
  end
end
