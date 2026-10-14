defmodule Alplus.Measure.DashboardShare.Checks.PublicPanelAllowed do
  @moduledoc false

  use Ash.Policy.SimpleCheck

  alias Alplus.Measure.ShareActor

  @dimension_panels %{
    path: :pages,
    referrer: :sources,
    event: :events,
    country: :countries,
    browser: :browsers
  }

  @impl true
  def describe(_opts), do: "the resolved share enables the requested panel"

  @impl true
  def match?(
        %ShareActor{
          share_id: share_id,
          org_id: org_id,
          project_id: project_id,
          source_id: source_id,
          environment: environment,
          panels: panels
        },
        %{
          subject: %{
            arguments: %{
              share_id: share_id,
              org_id: org_id,
              project_id: project_id,
              source_id: source_id,
              environment: environment,
              dimension: dimension
            }
          }
        },
        _opts
      ) do
    Map.get(@dimension_panels, dimension) in panels
  end

  def match?(_actor, _context, _opts), do: false
end
