defmodule Alplus.Measure.ShareActor do
  @moduledoc "The capability scope granted by one resolved Measure dashboard share token."

  defstruct [:share_id, :org_id, :project_id, :source_id, :environment, panels: []]
end
