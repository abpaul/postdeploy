defmodule Alplus.Status.Health do
  @moduledoc """
  Health aggregation for Status pages and services.

  `aggregate_health/4` and `service_state/1` are pure. `last_public_update_at/4`
  and `unhealthy_service_ids/2` read one bounded row set through
  `Alplus.Status.Queries` and then reduce it; no function here writes, and none
  runs inside a caller's transaction.
  """

  alias Alplus.Status.PublicPage
  alias Alplus.Status.Queries

  @doc """
  Aggregates the customer-visible status from service rows and page signals.

  Empty workspaces keep their caller-specific presentation state. Public pages
  use `:unknown`; the authenticated workspace uses `:unconfigured`.
  """
  @spec aggregate_health([map()], boolean(), atom() | nil, atom()) :: atom()
  def aggregate_health(services, maintenance?, incident_status \\ nil, empty_state \\ :unknown)

  def aggregate_health([], true, _incident_status, _empty_state), do: :maintenance

  def aggregate_health([], false, status, _empty_state) when status in [:down, :degraded],
    do: :degraded

  def aggregate_health([], false, _incident_status, empty_state), do: empty_state

  def aggregate_health(services, maintenance?, _incident_status, _empty_state)
      when is_list(services) do
    states = Enum.map(services, &service_state/1)
    down_count = Enum.count(states, &(&1 == :down))

    cond do
      down_count == length(states) -> :major_outage
      down_count > 0 -> :partial_outage
      :degraded in states -> :degraded
      maintenance? or :maintenance in states -> :maintenance
      :unknown in states -> :unknown
      true -> :operational
    end
  end

  defp service_state(%{state: :up}), do: :operational
  defp service_state(%{state: :operational}), do: :operational
  defp service_state(%{status: :up}), do: :operational
  defp service_state(%{status: :operational}), do: :operational
  defp service_state(%{state: state}), do: state
  defp service_state(%{status: status}), do: status
  defp service_state(_service), do: :unknown

  @doc "Returns the newest published incident or announcement update."
  @spec last_public_update_at(Alplus.Scope.t(), String.t(), list(), list()) ::
          DateTime.t() | nil
  def last_public_update_at(scope, page_id, incidents, announcements) do
    update_at = Queries.max_incident_update_at(scope, page_id)

    ([update_at | Enum.map(incidents, & &1.published_at)] ++
       Enum.map(Enum.filter(announcements, &is_nil(&1.removed_at)), & &1.published_at))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_utc_datetime/1)
    |> case do
      [] -> nil
      values -> Enum.max(values, DateTime)
    end
  end

  defp to_utc_datetime(%DateTime{} = value), do: value
  defp to_utc_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

  @doc "Service ids on this page whose linked monitor is down or degraded."
  @spec unhealthy_service_ids(Alplus.Scope.t(), String.t()) :: [String.t()]
  def unhealthy_service_ids(scope, page_id) do
    scope
    |> Queries.monitor_health_rows(page_id)
    |> Enum.filter(fn [_id, status, last_known_status] ->
      PublicPage.monitor_status(%{status: status, last_known_status: last_known_status}) in [
        :down,
        :degraded
      ]
    end)
    |> Enum.map(fn [id, _status, _last_known_status] -> id end)
    |> Enum.uniq()
  end
end
