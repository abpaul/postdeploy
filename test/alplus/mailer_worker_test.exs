defmodule Alplus.Mailer.WorkerTest do
  use Alplus.DataCase, async: false
  use Oban.Testing, repo: Alplus.Repo

  import Alplus.OrgsFixtures
  import Swoosh.TestAssertions

  alias Alplus.Mailer.Worker
  alias Alplus.Orgs.Invitation

  test "replaying one logical invitation delivery sends only once" do
    owner = scope_fixture()
    {org, owner_scope} = org_fixture(owner)
    {invitation, token} = invitation_fixture(owner_scope, org)
    email = to_string(invitation.email)

    assert [%{args: args}] =
             all_enqueued(
               worker: Worker,
               args: %{"purpose" => "invitation", "invitation_id" => invitation.id}
             )

    assert args["token"] == token
    assert :ok = perform_job(Worker, args)
    assert_email_sent(to: email)

    assert :ok = perform_job(Worker, args)
    refute_email_sent()
  end

  test "a revoked invitation job is a successful no-op" do
    owner = scope_fixture()
    {org, owner_scope} = org_fixture(owner)
    {invitation, _token} = invitation_fixture(owner_scope, org)

    assert [%{args: args}] =
             all_enqueued(
               worker: Worker,
               args: %{"purpose" => "invitation", "invitation_id" => invitation.id}
             )

    assert Ash.update!(invitation, %{}, action: :revoke, actor: owner_scope).status == "revoked"
    assert :ok = perform_job(Worker, args)
    refute_email_sent()
    assert_delivery_sent(args["record_id"])
  end

  test "an expired invitation job is a successful no-op" do
    owner = scope_fixture()
    {org, owner_scope} = org_fixture(owner)
    {invitation, _token} = invitation_fixture(owner_scope, org)

    assert [%{args: args}] =
             all_enqueued(
               worker: Worker,
               args: %{"purpose" => "invitation", "invitation_id" => invitation.id}
             )

    Alplus.Repo.query!(
      "UPDATE invitations SET inserted_at = $1, expires_at = $2 WHERE id = $3",
      [
        DateTime.add(DateTime.utc_now(), -2, :second),
        DateTime.add(DateTime.utc_now(), -1, :second),
        invitation.id
      ]
    )

    assert :ok = perform_job(Worker, args)
    refute_email_sent()
    assert_delivery_sent(args["record_id"])
  end

  test "a stale resend job is skipped while the current resend is delivered" do
    owner = scope_fixture()
    {org, owner_scope} = org_fixture(owner)
    {invitation, _old_token} = invitation_fixture(owner_scope, org)

    assert {:ok, resent} = Ash.update(invitation, %{}, action: :resend, actor: owner_scope)

    jobs =
      all_enqueued(
        worker: Worker,
        args: %{"purpose" => "invitation", "invitation_id" => invitation.id}
      )

    assert length(jobs) == 2

    assert %{args: old_args} =
             Enum.find(jobs, fn job -> job.args["record_id"] == invitation.token_hash end)

    assert %{args: current_args} =
             Enum.find(jobs, fn job -> job.args["record_id"] == resent.token_hash end)

    assert :ok = perform_job(Worker, old_args)
    refute_email_sent()
    assert_delivery_sent(old_args["record_id"])

    assert :ok = perform_job(Worker, current_args)
    assert_email_sent(to: to_string(invitation.email))
    assert_delivery_sent(current_args["record_id"])
  end

  defp assert_delivery_sent(record_id) do
    assert [["sent"]] =
             Alplus.Repo.query!(
               "SELECT status FROM mail_deliveries WHERE purpose = 'invitation' AND record_id = $1",
               [record_id]
             ).rows
  end

  test "a rolled-back invitation leaves no mail job" do
    owner = scope_fixture()
    {org, owner_scope} = org_fixture(owner)
    subscribed_fixture(org)
    email = "rollback-#{System.unique_integer([:positive])}@example.com"

    assert {:error, :rolled_back} =
             Alplus.Repo.transaction(fn ->
               assert {:ok, invitation} =
                        Ash.create(
                          Invitation,
                          %{org_id: org.id, email: email, role: "member"},
                          action: :invite,
                          actor: owner_scope
                        )

               send(self(), {:rolled_back_invitation, invitation.id})
               Alplus.Repo.rollback(:rolled_back)
             end)

    assert_received {:rolled_back_invitation, invitation_id}

    refute Enum.any?(all_enqueued(worker: Worker), fn job ->
             job.args["invitation_id"] == invitation_id
           end)
  end
end
