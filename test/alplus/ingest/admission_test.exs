defmodule Alplus.Ingest.AdmissionTest do
  use ExUnit.Case, async: false

  alias Alplus.Ingest.Admission

  setup do
    Admission.release_all()
    on_exit(&Admission.release_all/0)
  end

  test "a Source cannot consume more than its lane capacity" do
    assert :ok = Admission.acquire(:errors, {:tenant, "source_a"})
    assert :ok = Admission.acquire(:errors, {:tenant, "source_a"})
    assert {:error, :overloaded} = Admission.acquire(:errors, {:tenant, "source_a"})

    assert Admission.snapshot()[{:errors, {:tenant, "source_a"}}] == 2
  end

  test "one full tenant lane does not consume a sibling tenant lane" do
    assert :ok = Admission.acquire(:measure, {:tenant, "noisy"})
    assert :ok = Admission.acquire(:measure, {:tenant, "noisy"})
    assert {:error, :overloaded} = Admission.acquire(:measure, {:tenant, "noisy"})
    assert :ok = Admission.acquire(:measure, {:tenant, "normal"})
  end

  test "releasing a request returns every acquired lease" do
    assert :ok = Admission.acquire(:sessions, :global)
    assert :ok = Admission.acquire(:sessions, {:tenant, "source_a"})

    assert :ok = Admission.release_all()
    assert Admission.snapshot()[{:sessions, :global}] == 0
    assert Admission.snapshot()[{:sessions, {:tenant, "source_a"}}] == 0
  end
end
