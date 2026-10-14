defmodule Alplus.Observe.RetentionTest do
  use Alplus.DataCase, async: true

  alias Alplus.Observe.Retention

  test "pruning an organization with no Observe rows deletes nothing" do
    assert Retention.prune(Ecto.UUID.generate(), DateTime.utc_now()) == 0
  end
end
