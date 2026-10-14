defmodule Alplus.Content.PublishGate do
  @moduledoc """
  SITE-ARCHITECTURE.md §8's four-part publish gate for the reserved
  programmatic sets. Only `/guides/{platform}-heartbeat` is live today,
  identified here as every `Guide` row with `docs_host` set.

  Conditions 3 (cited platform documentation) and 4 (a stated non-capability)
  are per-row Ash validations (`Alplus.Content.Validations.*`) that run at
  write time. This module covers the two set-level conditions:

  * Condition 1, three or more fields differing materially between any two
    pages in the set: `differentiation_findings/1` below.
  * Condition 2, "the code sample is executed, not written from memory,"
    cannot be proven from the page itself. This module only approximates
    it: it parses each code block with a real parser where one exists
    (JSON, `YamlElixir`), resolves every PostDeploy URL found inside against
    `AlplusWeb.Router`, and requires a recorded `code_verified_on` date.
    Page copy and code samples have separate revision lifecycles, so a newer
    page `lastmod` does not invalidate an unchanged sample. Whether a human
    actually ran the sample stays a manual step this cannot check.
  """

  @gated_fields [:platform, :docs_host, :platform_failure_mode, :sources, :not_offered]
  @min_material_fields 3

  # Any PostDeploy-owned host: the marketing/console origin and the ingest
  # subdomain the heartbeat examples ping.
  @url_regex ~r{https://[a-zA-Z0-9.-]*postdeploy\.dev(/[^\s"'<>]*)?}

  @type finding :: %{severity: :error, path: String.t(), check: atom(), message: String.t()}

  @doc """
  Runs both set-level checks against every `Guide` row that participates in
  the publish gate. Rows with no `docs_host` (most `Guide` rows: `/privacy`,
  `/monitoring`, ...) are not part of any reserved programmatic set and are
  ignored.
  """
  @spec report([Alplus.Content.Guide.t()]) :: [finding()]
  def report(guides) do
    gated = Enum.filter(guides, &(&1.docs_host not in [nil, ""]))

    differentiation_findings(gated) ++ code_sample_findings(gated)
  end

  # -- condition 1: 3+ materially different fields between any two pages ---

  defp differentiation_findings(guides) do
    for {a, b} <- pairs(guides),
        count = differing_field_count(a, b),
        count < @min_material_fields,
        {this, other} <- [{a, b}, {b, a}] do
      finding(
        this.path,
        :publish_gate_insufficient_differentiation,
        "only #{count} of #{Enum.join(@gated_fields, ", ")} differ from #{other.path}; " <>
          "needs #{@min_material_fields} or more materially different fields"
      )
    end
  end

  defp pairs(list) do
    for {a, i} <- Enum.with_index(list),
        {b, j} <- Enum.with_index(list),
        i < j,
        do: {a, b}
  end

  defp differing_field_count(a, b) do
    Enum.count(@gated_fields, fn field -> Map.get(a, field) != Map.get(b, field) end)
  end

  # -- condition 2 approximation: parseable code samples resolve, and a
  # human has recorded an earlier end-to-end run --------------------------

  defp code_sample_findings(guides), do: Enum.flat_map(guides, &code_sample_findings_for/1)

  defp code_sample_findings_for(guide) do
    attestation_findings(guide) ++ broken_url_findings(guide)
  end

  defp attestation_findings(%{code_verified_on: nil} = guide) do
    [finding(guide.path, :code_sample_not_verified, "code_verified_on is not set")]
  end

  defp attestation_findings(_guide), do: []

  defp broken_url_findings(guide) do
    guide.body_sections
    |> Enum.flat_map(&parsed_code_strings/1)
    |> Enum.flat_map(&postdeploy_urls_with_paths/1)
    |> Enum.uniq()
    |> Enum.reject(&resolves?/1)
    |> Enum.map(fn url ->
      finding(
        guide.path,
        :code_sample_url_unresolved,
        "code sample references #{url}, which does not resolve against the router"
      )
    end)
  end

  defp parsed_code_strings(%{"code" => code}) when is_binary(code) do
    case parse(code) do
      {:ok, parsed} -> collect_strings(parsed)
      :error -> []
    end
  end

  defp parsed_code_strings(_section), do: []

  defp parse(code) do
    case Jason.decode(code) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, _} ->
        case YamlElixir.read_all_from_string(code) do
          {:ok, docs} -> {:ok, docs}
          {:error, _} -> :error
        end
    end
  end

  defp collect_strings(value) when is_binary(value), do: [value]

  defp collect_strings(value) when is_map(value),
    do: Enum.flat_map(Map.values(value), &collect_strings/1)

  defp collect_strings(value) when is_list(value), do: Enum.flat_map(value, &collect_strings/1)
  defp collect_strings(_value), do: []

  defp postdeploy_urls_with_paths(text) do
    @url_regex
    |> Regex.scan(text)
    |> Enum.map(&hd/1)
    |> Enum.filter(&has_path?/1)
  end

  defp has_path?(url) do
    case URI.parse(url) do
      %URI{path: path} when is_binary(path) and path not in ["", "/"] -> true
      _ -> false
    end
  end

  defp resolves?(url) do
    case Phoenix.Router.route_info(AlplusWeb.Router, "GET", URI.parse(url).path, %{}) do
      :error -> false
      _ -> true
    end
  end

  defp finding(path, check, message),
    do: %{severity: :error, path: path, check: check, message: message}
end
