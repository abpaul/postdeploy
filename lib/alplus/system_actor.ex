defmodule Alplus.SystemActor do
  @moduledoc "Explicit actor marker for isolated system workflows without a user owner."

  defstruct [:org_id, :project_id]
end
