defmodule Alplus.Accounts.ResendConfirmationTest do
  use AlplusWeb.ConnCase, async: false
  use Oban.Testing, repo: Alplus.Repo
  import Alplus.OrgsFixtures

  alias Alplus.Accounts.ResendConfirmation
  alias Alplus.Mailer.Worker

  test "queues a fresh confirmation email for an unconfirmed user" do
    user = user_fixture(%{confirmed: false})

    assert :ok = ResendConfirmation.resend(user)

    assert length(all_enqueued(worker: Worker, args: %{"user_id" => user.id})) == 2
  end

  test "refuses to resend for an already-confirmed user" do
    user = user_fixture(%{confirmed: true})
    before = all_enqueued(worker: Worker, args: %{"user_id" => user.id})

    assert {:error, :already_confirmed} = ResendConfirmation.resend(user)
    assert all_enqueued(worker: Worker, args: %{"user_id" => user.id}) == before
  end
end
