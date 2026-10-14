defmodule Alplus.Measure.SourceOverview do
  @moduledoc """
  Builds the source-scoped read model used by the Measure overview.

  A Source is the authority for identity, environment, status, and token
  lifecycle. Project domains remain the authority for browser-origin setup.
  The two are joined by the persisted Source hostname. Sources created before
  that field existed remain explicitly unconfigured until an origin is added.
  """

  alias Alplus.Measure.OriginAllowlist
  alias Alplus.Projects.ProjectDomain

  @type t :: %{
          source: map(),
          summary: map(),
          identity: map(),
          domain: map(),
          token: map(),
          installation_state: atom(),
          traffic_state: atom(),
          recent: map(),
          trend: list(),
          data_source: String.t() | nil
        }

  @doc "Builds one independent overview row for each Source."
  @spec build([map()], map(), [ProjectDomain.t()]) :: [t()]
  def build(sources, summaries, domains) when is_list(sources) and is_map(summaries) do
    domain_rows = Enum.filter(domains, &match?(%ProjectDomain{}, &1))

    Enum.map(sources, fn source ->
      summary = Map.get(summaries, source.id, empty_summary())
      hostname = source_hostname(source)
      domain = domain_for(source, hostname, domain_rows)
      traffic_state = traffic_state(source, summary)

      %{
        source: source,
        summary: summary,
        identity: %{
          id: source.id,
          name: source.name,
          environment: source.environment,
          hostname: hostname
        },
        domain: %{
          id: domain && domain.id,
          hostname: hostname,
          state: domain_state(hostname, domain),
          configured?: not is_nil(domain)
        },
        token: %{
          state: token_state(source),
          present?: is_binary(source.measure_token) and source.measure_token != "",
          value: if(source.status == :active, do: source.measure_token)
        },
        installation_state: installation_state(source, domain, summary, traffic_state),
        traffic_state: traffic_state,
        recent: %{
          pageviews: get_in(summary, [:totals, :pageviews]) || 0,
          visitors: get_in(summary, [:totals, :visitors]) || 0,
          visits: get_in(summary, [:totals, :visits]) || 0,
          evidence?: Map.get(summary, :evidence?, false),
          first_pageview_on: get_in(summary, [:evidence, :first_pageview_on]),
          last_pageview_on: get_in(summary, [:evidence, :last_pageview_on])
        },
        trend: Map.get(summary, :trend, []),
        data_source: Map.get(summary, :data_source),
        data_source_key: Map.get(summary, :data_source_key),
        analytics_engine_state: Map.get(summary, :analytics_engine_state),
        analytics_engine_partial?: Map.get(summary, :analytics_engine_partial?, false),
        analytics_engine_unavailable?: Map.get(summary, :analytics_engine_unavailable?, false),
        fallback?: Map.get(summary, :fallback?, false),
        unavailable?: Map.get(summary, :unavailable?, false),
        actions: %{
          open?: true,
          copy_snippet?:
            source.status == :active and is_binary(source.measure_token) and
              source.measure_token != "",
          rotate?: source.status == :active,
          revoke?: source.status == :active
        }
      }
    end)
  end

  @doc "Returns the normalized hostname used to join a Source to its domain."
  def source_hostname(source) do
    case Map.get(source, :hostname) do
      hostname when is_binary(hostname) and hostname != "" -> hostname
      _missing -> nil
    end
  end

  defp domain_for(_source, nil, _domains), do: nil

  defp domain_for(source, hostname, domains) do
    Enum.find(domains, fn %ProjectDomain{hostname: configured} = domain ->
      domain_scope_matches?(source, domain) and
        (configured == hostname or OriginAllowlist.allowed?(hostname, [configured]))
    end)
  end

  defp domain_scope_matches?(source, domain) do
    Enum.all?([:org_id, :project_id], fn field ->
      source_value = Map.get(source, field)
      domain_value = Map.get(domain, field)
      is_nil(source_value) or is_nil(domain_value) or source_value == domain_value
    end)
  end

  defp domain_state(nil, _domain), do: :not_configured
  defp domain_state(_hostname, %ProjectDomain{}), do: :allowlisted
  defp domain_state(_hostname, _domain), do: :missing

  defp token_state(%{status: :revoked}), do: :revoked
  defp token_state(%{measure_token: token}) when is_binary(token) and token != "", do: :active
  defp token_state(_source), do: :missing

  defp installation_state(%{status: :revoked}, _domain, _summary, _traffic_state),
    do: :revoked

  defp installation_state(_source, nil, _summary, traffic_state)
       when traffic_state in [:receiving, :zero_traffic],
       do: traffic_state

  defp installation_state(_source, nil, _summary, _traffic_state), do: :not_installed

  defp installation_state(_source, _domain, %{unavailable?: true}, _traffic_state),
    do: :unavailable

  defp installation_state(_source, _domain, _summary, :waiting), do: :installed_waiting
  defp installation_state(_source, _domain, _summary, :zero_traffic), do: :zero_traffic
  defp installation_state(_source, _domain, _summary, :receiving), do: :receiving
  defp installation_state(_source, _domain, _summary, state), do: state

  defp traffic_state(%{status: :revoked}, _summary), do: :revoked
  defp traffic_state(_source, %{unavailable?: true}), do: :unavailable
  defp traffic_state(_source, %{evidence?: true, totals: %{pageviews: 0}}), do: :zero_traffic

  defp traffic_state(_source, %{totals: %{pageviews: pageviews}}) when pageviews > 0,
    do: :receiving

  defp traffic_state(_source, _summary), do: :waiting

  defp empty_summary do
    %{
      totals: %{pageviews: 0, visitors: 0, visits: 0},
      trend: [],
      data_source: nil,
      data_source_key: nil,
      analytics_engine_state: nil,
      analytics_engine_partial?: false,
      analytics_engine_unavailable?: false,
      evidence?: false,
      unavailable?: false,
      fallback?: false,
      evidence: %{}
    }
  end
end
