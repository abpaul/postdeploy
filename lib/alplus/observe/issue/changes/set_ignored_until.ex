defmodule Alplus.Observe.Issue.Changes.SetIgnoredUntil do
  @moduledoc false

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.change_attribute(
      changeset,
      :ignored_until,
      DateTime.add(DateTime.utc_now(), 90, :day)
    )
  end
end
