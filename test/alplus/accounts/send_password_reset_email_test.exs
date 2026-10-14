defmodule Alplus.Accounts.User.Senders.SendPasswordResetEmailTest do
  use Alplus.DataCase, async: true

  test "builds a reset email containing the token URL in both parts" do
    user = %{email: "reset-#{System.unique_integer([:positive])}@example.com"}
    email = Alplus.Accounts.User.Senders.SendPasswordResetEmail.build(user, "tok_test", %{})

    assert inspect(email.to) =~ user.email
    assert email.subject =~ "Reset"
    assert email.html_body =~ "tok_test"
    # A single-link HTML-only body gets silently discarded by strict
    # receivers (iCloud), so the text alternative is part of the contract.
    assert email.text_body =~ "tok_test"
    assert email.text_body =~ "Reset your password"
  end
end
