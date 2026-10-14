defmodule AlplusWeb.OnboardingTest do
  use ExUnit.Case, async: true

  alias AlplusWeb.Onboarding

  test "later rows stay todo after the first incomplete step" do
    steps = [
      %{key: :organization, title: "Org", description: "", done?: true},
      %{key: :project, title: "Project", description: "", done?: false},
      %{key: :integrate, title: "Integrate", description: "", done?: true},
      %{key: :first_value, title: "Value", description: "", done?: true}
    ]

    marked = Onboarding.mark_states(steps)

    assert Enum.map(marked, & &1.state) == [:done, :current, :todo, :todo]
    assert Onboarding.done_count(marked) == 3
    refute Onboarding.complete?(marked)
  end

  test "activation requires verified connection evidence, not a credential" do
    credential_only =
      Onboarding.activation(%{
        user_confirmed?: true,
        organization: %{id: "organization"},
        project: %{id: "project"},
        credential: %{id: "credential"}
      })

    assert Onboarding.first_incomplete(credential_only) == :connection
    refute Enum.find(credential_only, &(&1.key == :connection)).done?

    verified =
      Onboarding.activation(%{
        user_confirmed?: true,
        organization: %{id: "organization"},
        project: %{id: "project"},
        audit: %{outcome: "allowed"}
      })

    assert Enum.find(verified, &(&1.key == :connection)).done?
    assert Onboarding.first_incomplete(verified) == :analysis
  end
end
