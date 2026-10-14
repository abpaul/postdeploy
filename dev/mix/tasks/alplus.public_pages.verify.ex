defmodule Mix.Tasks.Alplus.PublicPages.Verify do
  @shortdoc "Verify the singleton public-page migration"

  use Mix.Task

  alias Alplus.PublicPages.Verification

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case Verification.run() do
      :ok ->
        Mix.shell().info("Public-page verification passed.")
        print_relationship_counts()

      {:error, findings} ->
        Enum.each(findings, &Mix.shell().error(inspect(&1)))
        Mix.raise("Public-page verification failed.")
    end
  end

  defp print_relationship_counts do
    Verification.relationship_counts()
    |> Enum.each(fn %{relation: relation, row_count: row_count} ->
      Mix.shell().info("#{relation}: #{row_count} retired-workspace rows")
    end)
  end
end
