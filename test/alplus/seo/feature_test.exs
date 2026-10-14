defmodule Alplus.Seo.FeatureTest do
  use ExUnit.Case, async: false

  alias Alplus.Seo.Feature

  setup do
    original = Application.get_env(:alplus, :seo_enabled_org_ids, [])

    on_exit(fn ->
      Application.put_env(:alplus, :seo_enabled_org_ids, original)
    end)
  end

  test "fails closed when no organization is enabled" do
    Application.put_env(:alplus, :seo_enabled_org_ids, [])

    refute Feature.enabled?("org_postdeploy")
    refute Feature.enabled?(nil)
  end

  test "permits only listed organization ids" do
    Application.put_env(:alplus, :seo_enabled_org_ids, ["org_postdeploy"])

    assert Feature.enabled?("org_postdeploy")
    refute Feature.enabled?("org_other")
  end
end
