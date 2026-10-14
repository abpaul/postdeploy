defmodule Alplus.Accounts.UpdateProfileTest do
  @moduledoc """
  `Alplus.Accounts.User`'s `:update_profile` action (issue #5). Name changes
  are immediate; email changes stage a new address and re-verify it via a
  second, independent confirmation add-on (`:confirm_email_change`) before
  it becomes the login identity — see the moduledoc in
  `Alplus.Accounts.User` for why this is not a `confirm_on_update?: true`
  flip on `confirm_new_user` itself.
  """

  use Alplus.DataCase, async: false
  use Oban.Testing, repo: Alplus.Repo

  import Swoosh.TestAssertions
  import Alplus.OrgsFixtures

  alias Alplus.Accounts.User
  alias Alplus.Mailer.Worker

  defp deliver_email_change(user) do
    assert [%{args: args}] =
             all_enqueued(
               worker: Worker,
               args: %{"purpose" => "email_change", "user_id" => user.id}
             )

    assert :ok = perform_job(Worker, args)
  end

  describe "name changes (immediate)" do
    test "a user updates their own display name and it persists" do
      user = user_fixture()
      scope = Alplus.Scope.for_user(user.id)

      assert {:ok, updated} =
               Ash.update(user, %{name: "Ada Lovelace"}, action: :update_profile, actor: scope)

      assert updated.name == "Ada Lovelace"
      assert Ash.get!(User, user.id, authorize?: false).name == "Ada Lovelace"
    end

    test "a user clears a previously-set name with an empty string, not a validation error" do
      user = user_fixture()
      scope = Alplus.Scope.for_user(user.id)

      user = Ash.update!(user, %{name: "Ada Lovelace"}, action: :update_profile, actor: scope)
      assert user.name == "Ada Lovelace"

      assert {:ok, cleared} =
               Ash.update(user, %{name: ""}, action: :update_profile, actor: scope)

      assert is_nil(cleared.name)
      assert is_nil(Ash.get!(User, user.id, authorize?: false).name)
    end

    test "a user cannot update another user's profile" do
      owner = user_fixture()
      other = user_fixture()
      other_scope = Alplus.Scope.for_user(other.id)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.update(owner, %{name: "Hijacked"}, action: :update_profile, actor: other_scope)

      assert is_nil(Ash.get!(User, owner.id, authorize?: false).name)
    end
  end

  describe "email changes (staged, re-verified)" do
    test "requesting an email change stages the address and queues it, without changing the login email" do
      user = user_fixture()
      scope = Alplus.Scope.for_user(user.id)
      new_email = unique_email()

      assert {:ok, updated} =
               Ash.update(user, %{email: new_email}, action: :update_profile, actor: scope)

      assert to_string(updated.email) == to_string(user.email)
      assert to_string(Ash.get!(User, user.id, authorize?: false).email) == to_string(user.email)

      deliver_email_change(user)
      assert_email_sent(to: {"", new_email})
      assert Ash.get!(User, user.id, authorize?: false).confirmed_at
    end

    test "confirming the token flips the email and leaves the login gate confirmed" do
      user = user_fixture()
      scope = Alplus.Scope.for_user(user.id)
      new_email = unique_email()

      updated =
        Ash.update!(user, %{email: new_email}, action: :update_profile, actor: scope)

      token =
        updated.__metadata__[:confirmation_token] ||
          raise "expected a confirmation token in metadata"

      assert {:ok, confirmed} =
               Ash.update(updated, %{confirm: token},
                 action: :confirm_email_change,
                 authorize?: false
               )

      assert to_string(confirmed.email) == to_string(new_email)
      assert confirmed.confirmed_at
    end

    test "another actor cannot request an email change for someone else" do
      owner = user_fixture()
      other = user_fixture()
      other_scope = Alplus.Scope.for_user(other.id)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.update(owner, %{email: unique_email()},
                 action: :update_profile,
                 actor: other_scope
               )
    end

    test "a duplicate email is rejected with a clear error, not a constraint failure" do
      user = user_fixture()
      scope = Alplus.Scope.for_user(user.id)
      taken = user_fixture()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Ash.update(user, %{email: to_string(taken.email)},
                 action: :update_profile,
                 actor: scope
               )

      assert Enum.any?(errors, &(&1.message =~ "taken"))
    end
  end
end
