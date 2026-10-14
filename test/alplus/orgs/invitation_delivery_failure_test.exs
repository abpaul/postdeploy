defmodule Alplus.TestMailerFailureAdapter do
  use Swoosh.Adapter

  @impl true
  def deliver(_email, _config), do: {:error, :forced_mailer_failure}
end

defmodule Alplus.Orgs.InvitationDeliveryFailureTest do
  use Alplus.DataCase, async: false
  use Oban.Testing, repo: Alplus.Repo

  import Alplus.OrgsFixtures

  require Ash.Query

  alias Alplus.Mailer.Worker
  alias Alplus.Orgs.Invitation

  setup do
    original = Application.get_env(:alplus, Alplus.Mailer)

    on_exit(fn ->
      if original do
        Application.put_env(:alplus, Alplus.Mailer, original)
      else
        Application.delete_env(:alplus, Alplus.Mailer)
      end
    end)

    :ok
  end

  test "invite commits and a mail failure remains retryable" do
    owner = scope_fixture()
    {org, owner_scope} = org_fixture(owner)
    subscribed_fixture(org)
    use_failing_mailer()

    assert {:ok, invitation} =
             Ash.create(
               Invitation,
               %{org_id: org.id, email: "delivery-fails@example.com", role: "member"},
               action: :invite,
               actor: owner_scope
             )

    assert [%{args: args}] =
             all_enqueued(
               worker: Worker,
               args: %{"purpose" => "invitation", "invitation_id" => invitation.id}
             )

    assert {:error, :mail_delivery_failed} = perform_job(Worker, args)

    assert {:ok, %{status: "pending"}} =
             Invitation
             |> Ash.Query.filter(id == ^invitation.id)
             |> Ash.read_one(actor: owner_scope)
  end

  test "resend commits the new token even when delivery fails" do
    owner = scope_fixture()
    {org, owner_scope} = org_fixture(owner)
    {invitation, _token} = invitation_fixture(owner_scope, org)
    use_failing_mailer()

    assert {:ok, resent} = Ash.update(invitation, %{}, action: :resend, actor: owner_scope)
    assert resent.token_hash != invitation.token_hash
    assert resent.expires_at != invitation.expires_at

    jobs =
      all_enqueued(
        worker: Worker,
        args: %{"purpose" => "invitation", "invitation_id" => invitation.id}
      )

    assert length(jobs) == 2
    args = jobs |> Enum.max_by(& &1.id) |> Map.fetch!(:args)

    assert {:error, :mail_delivery_failed} = perform_job(Worker, args)
    assert {:ok, reloaded} = Ash.get(Invitation, invitation.id, actor: owner_scope)
    assert reloaded.token_hash == resent.token_hash
    assert reloaded.status == "pending"
  end

  defp use_failing_mailer do
    Application.put_env(:alplus, Alplus.Mailer, adapter: Alplus.TestMailerFailureAdapter)
  end
end

defmodule AlplusWeb.TeamLiveInvitationDeliveryFailureTest do
  use AlplusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Alplus.OrgsFixtures

  require Ash.Query

  alias Alplus.Orgs.Invitation

  setup do
    original = Application.get_env(:alplus, Alplus.Mailer)

    on_exit(fn ->
      if original do
        Application.put_env(:alplus, Alplus.Mailer, original)
      else
        Application.delete_env(:alplus, Alplus.Mailer)
      end
    end)

    :ok
  end

  test "TeamLive shows success while mail delivery remains retryable", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    subscribed_fixture(org)
    Application.put_env(:alplus, Alplus.Mailer, adapter: Alplus.TestMailerFailureAdapter)

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(~p"/dashboard/orgs/#{org.id}/team")

    view |> element("#invite-toggle") |> render_click()

    view
    |> form("#invite-form",
      invitation: %{email: "live-delivery-fails@example.com", role: "member"}
    )
    |> render_submit()

    html = render(view)
    assert html =~ "Invitation sent to live-delivery-fails@example.com"
    refute html =~ "The invitation was not created"
    refute html =~ "Invitation email could not be handed off"

    assert {:ok, invitation} =
             Invitation
             |> Ash.Query.filter(org_id == ^org.id and email == "live-delivery-fails@example.com")
             |> Ash.read_one(actor: owner_scope)

    assert invitation.status == "pending"
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
