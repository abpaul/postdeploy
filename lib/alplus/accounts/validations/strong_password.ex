defmodule Alplus.Accounts.Validations.StrongPassword do
  @moduledoc """
  Server-side password strength check (ARCHITECTURE.md §10): a minimum
  length plus a small deny-list of known-weak passwords. Runs as an Ash
  validation so it applies no matter which surface calls the action.

  Usage: `validate {Alplus.Accounts.Validations.StrongPassword, argument: :password}`
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidArgument

  @min_length 12

  # A short, deliberately small deny-list of passwords that are common
  # enough to be guessed in an online attack even at 12+ characters.
  # HIBP (Alplus.Accounts.Validations.NotPwned) covers the broader
  # breach-corpus check; this list is a fast, offline backstop.
  @weak_passwords MapSet.new(~w(
    password password123 password1234 12345678901 123456789012
    qwertyuiop123 qwertyuiop1234 letmein12345 admin12345678
    welcome12345 iloveyou12345 monkey1234567 dragon12345678
    sunshine12345 princess12345 football12345 baseball12345
    trustno112345 changeme12345 whatever12345 superman12345
  ))

  @impl true
  def validate(changeset, opts, _context) do
    argument = Keyword.fetch!(opts, :argument)

    case Ash.Changeset.get_argument(changeset, argument) do
      nil -> :ok
      password -> check(password, argument)
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: validate(changeset, opts, context)

  defp check(password, argument) do
    cond do
      String.length(password) < @min_length ->
        {:error,
         InvalidArgument.exception(
           field: argument,
           message: "must be at least %{min} characters",
           vars: [min: @min_length]
         )}

      MapSet.member?(@weak_passwords, String.downcase(password)) ->
        {:error,
         InvalidArgument.exception(
           field: argument,
           message: "is too common. Choose a different password."
         )}

      true ->
        :ok
    end
  end
end
