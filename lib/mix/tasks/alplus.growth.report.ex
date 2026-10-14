defmodule Mix.Tasks.Alplus.Growth.Report do
  @shortdoc "Reports the organic acquisition funnel by content cluster"

  @moduledoc """
  Prints the acquisition funnel, from attributed signup through to
  activated organization, broken down by content cluster.

      mix alplus.growth.report
      mix alplus.growth.report --days 28

  This answers the question that matters about content, which is whether it
  produced activated organizations, rather than whether it ranked. Rankings
  are a leading indicator we do not control; activation is an outcome we do.

  Activation means a real signal arrived: a check result, an error issue, or
  a day of analytics. See `Alplus.Growth.Funnel` for why that definition,
  and not "registered", is the one worth reporting.

  Impressions and clicks are deliberately absent. They come from Search
  Console, which this application has no credentials for, and inventing them
  would be worse than omitting them. See `docs/growth-implementation.md` for
  the manual checklist.
  """

  use Mix.Task

  alias Alplus.Growth.Funnel

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [days: :integer])
    days = Keyword.get(opts, :days, 28)
    since = DateTime.add(DateTime.utc_now(), -days * 24, :hour)

    by_cluster = Funnel.by_cluster(since)
    totals = Funnel.totals(since)

    Mix.shell().info("""

    PostDeploy organic funnel, last #{days} days
    #{String.duplicate("=", 60)}
    """)

    if by_cluster == %{} do
      Mix.shell().info("""
      No attributed signups in this window.

      This is the expected result before launch, or on a fresh database.
      It is not the same as a failing funnel.
      """)
    else
      report(by_cluster, totals)
    end

    Mix.shell().info(health_check_report(Funnel.health_check(since)))
  end

  defp report(by_cluster, totals) do
    Mix.shell().info(header())

    by_cluster
    |> Enum.sort_by(fn {_cluster, counts} -> -counts.signups end)
    |> Enum.each(fn {cluster, counts} -> Mix.shell().info(row(cluster, counts)) end)

    Mix.shell().info(String.duplicate("-", 60))
    Mix.shell().info(row("TOTAL", totals))

    Mix.shell().info(verdict(totals))
  end

  defp header do
    "#{pad("cluster", 16)}#{pad("signups", 10)}#{pad("project", 10)}" <>
      "#{pad("config", 10)}#{pad("active", 10)}rate\n" <> String.duplicate("-", 60)
  end

  defp row(label, counts) do
    rate =
      case Funnel.activation_rate(counts) do
        nil -> "n/a"
        value -> "#{Float.round(value * 100, 1)}%"
      end

    pad(label, 16) <>
      pad(counts.signups, 10) <>
      pad(counts.projects, 10) <>
      pad(counts.configured, 10) <> pad(counts.activated, 10) <> rate
  end

  defp verdict(totals) do
    case Funnel.activation_vs_target(totals) do
      :no_data ->
        "\nNo signups yet, so there is no activation rate to judge."

      {:ok, %{rate: rate, target: target, meets_target?: true}} ->
        "\nActivation #{percent(rate)} meets the #{percent(target)} target."

      {:ok, %{rate: rate, target: target, meets_target?: false}} ->
        """

        Activation #{percent(rate)} is below the #{percent(target)} target.

        The gap between 'configured' and 'active' is where onboarding is
        losing people: they pointed PostDeploy at something and never saw it work.
        """
    end
  end

  defp percent(value), do: "#{Float.round(value * 100, 1)}%"

  defp health_check_report(counts) do
    """

    Website health check
    #{String.duplicate("-", 60)}
    started #{counts["health_check_started"]}  result #{counts["health_check_result_produced"]}  signup #{counts["signup"]}  configured #{counts["configured"]}  activated #{counts["activated"]}
    """
  end

  defp pad(value, width), do: value |> to_string() |> String.pad_trailing(width)
end
