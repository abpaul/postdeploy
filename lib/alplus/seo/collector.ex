defmodule Alplus.Seo.Collector do
  @moduledoc "Builds the fixed organic-only DataForSEO collection and normalizes its response."

  alias Alplus.Seo.DataForSeo

  @limit 100

  def collect(profile, competitors) do
    with {:ok, overview} <- post("domain_rank_overview", target_task(profile.target, profile)),
         {:ok, keywords} <- post("ranked_keywords", ranked_task(profile.target, profile)),
         {:ok, pages} <- post("relevant_pages", ranked_task(profile.target, profile)),
         {:ok, competitor_rows} <- collect_competitors(profile, competitors) do
      {:ok,
       %{
         overview: overview(overview),
         keywords: items(keywords),
         pages: items(pages),
         competitors: competitor_rows,
         cost_microusd:
           costs([overview, keywords, pages | Enum.map(competitor_rows, & &1.response)])
       }}
    end
  end

  defp collect_competitors(profile, competitors) do
    competitors
    |> Enum.reduce_while({:ok, []}, fn competitor, {:ok, rows} ->
      with {:ok, overview} <-
             post("domain_rank_overview", target_task(competitor.target, profile)),
           {:ok, gap} <-
             post("domain_intersection", intersection_task(profile, competitor.target)) do
        row = %{
          target: competitor.target,
          overview: overview(overview),
          gaps: items(gap),
          response: [overview, gap]
        }

        {:cont, {:ok, [row | rows]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp post(endpoint, task) do
    with {:ok, response} <- DataForSeo.post("dataforseo_labs/google/#{endpoint}/live", [task]),
         :ok <- successful_task?(response) do
      {:ok, response}
    end
  end

  defp target_task(target, profile),
    do: Map.merge(base_task(profile), %{target: provider_target(target)})

  defp ranked_task(target, profile),
    do: Map.merge(target_task(target, profile), %{limit: @limit, item_types: ["organic"]})

  defp intersection_task(profile, competitor),
    do:
      Map.merge(base_task(profile), %{
        target1: provider_target(profile.target),
        target2: provider_target(competitor),
        limit: @limit,
        item_types: ["organic"],
        intersections: false
      })

  defp base_task(profile),
    do: %{location_code: profile.location_code, language_code: profile.language_code}

  defp provider_target("www." <> target), do: target
  defp provider_target(target), do: target

  defp overview(response) do
    response
    |> first_result()
    |> Map.get("items", [])
    |> List.first()
    |> Map.get("metrics", %{})
    |> Map.get("organic", %{})
  end

  defp items(response),
    do: response |> first_result() |> Map.get("items", []) |> Enum.take(@limit)

  defp first_result(%{"tasks" => [task | _]}) do
    case task do
      %{"result" => [result | _]} ->
        result

      _ ->
        %{}
    end
  end

  defp first_result(_), do: %{}

  defp successful_task?(%{"tasks" => [%{"status_code" => code} | _]}) when code < 40_000, do: :ok

  defp successful_task?(%{"tasks" => [%{"status_message" => message} | _]}),
    do: {:error, {:provider_task_error, message}}

  defp successful_task?(_), do: {:error, :provider_response_invalid}

  defp costs(responses) do
    responses
    |> List.flatten()
    |> Enum.reduce(0, fn response, total ->
      total + dollars_to_microusd(Map.get(response, "cost", 0))
    end)
  end

  defp dollars_to_microusd(value) when is_number(value), do: round(value * 1_000_000)
  defp dollars_to_microusd(_), do: 0
end
