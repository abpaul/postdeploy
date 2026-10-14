defmodule Alplus.Test.UnavailableMonitorOverview do
  @moduledoc false

  def load!(_project, _scope, _filters) do
    raise DBConnection.ConnectionError, "forced unavailable overview read"
  end
end
