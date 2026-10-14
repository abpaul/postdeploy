defmodule Alplus.Seo.Feature do
  @moduledoc "Fail-closed organization gate for the SEO pilot."

  alias Alplus.Scope

  @spec enabled?(Scope.t() | String.t() | nil) :: boolean()
  def enabled?(%Scope{org_id: org_id}), do: enabled?(org_id)

  def enabled?(org_id) when is_binary(org_id) do
    org_id in Application.get_env(:alplus, :seo_enabled_org_ids, [])
  end

  def enabled?(_org_id), do: false
end
