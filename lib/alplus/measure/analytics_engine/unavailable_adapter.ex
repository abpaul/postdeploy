defmodule Alplus.Measure.AnalyticsEngine.UnavailableAdapter do
  @moduledoc false

  @behaviour Alplus.Measure.AnalyticsEngine

  @impl true
  def write(_points), do: {:error, :unconfigured}

  @impl true
  def recent(_source_id, _since), do: {:error, :unconfigured}

  @impl true
  def recent_many(_source_ids, _since), do: {:error, :unconfigured}

  @impl true
  def coverage_since, do: :unknown
end
