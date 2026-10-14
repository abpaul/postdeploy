defmodule Alplus.Billing.StripeAdapterTest do
  use ExUnit.Case, async: true

  alias Alplus.Billing.StripeAdapter

  test "create_checkout_session returns stripe errors" do
    assert {:error, _} = StripeAdapter.create_checkout_session(%{})
  end

  test "create_portal_session returns stripe errors" do
    assert {:error, _} = StripeAdapter.create_portal_session(%{})
  end
end
