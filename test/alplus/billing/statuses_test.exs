defmodule Alplus.Billing.StatusesTest do
  @moduledoc """
  The status vocabulary must match between the Ash resources and the database
  CHECK constraints. A drift means a value the resource accepts is rejected by
  Postgres at insert time.

  These tests query the constraints that exist in the database, not the text of
  the migrations that created them.
  """

  use Alplus.DataCase, async: true

  alias Alplus.Billing.Statuses

  defp check_values(constraint) do
    sql = "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = $1"

    %{rows: [[definition]]} = Ecto.Adapters.SQL.query!(Alplus.Repo, sql, [constraint])

    Regex.scan(~r/'([a-z_]+)'::text/, definition)
    |> Enum.map(fn [_, value] -> value end)
    |> Enum.sort()
  end

  test "the subscription status constraint accepts exactly the resource vocabulary" do
    expected = Statuses.subscription() |> Enum.map(&to_string/1) |> Enum.sort()

    assert check_values("subscriptions_status_check") == expected
  end

  test "organization plan status uses the same vocabulary as subscription status" do
    assert check_values("organizations_plan_status_check") ==
             check_values("subscriptions_status_check")
  end

  test "the database rejects a status outside the vocabulary" do
    # The constraint has to bite on a real write, not merely exist.
    error =
      assert_raise Postgrex.Error, fn ->
        Ecto.Adapters.SQL.query!(
          Alplus.Repo,
          "INSERT INTO organizations (id, name, plan_id, plan_status, trial_ends_at) " <>
            "VALUES (gen_random_uuid(), 'probe', 'trial', 'not_a_status', now())",
          []
        )
      end

    assert error.postgres.constraint == "organizations_plan_status_check"
  end

  test "invoice and webhook statuses are non-empty and lower snake case" do
    for status <- Statuses.invoice() ++ Statuses.webhook_event() do
      assert to_string(status) =~ ~r/^[a-z][a-z_]*$/
    end
  end
end
