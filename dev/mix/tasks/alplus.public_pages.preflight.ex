defmodule Mix.Tasks.Alplus.PublicPages.Preflight do
  @shortdoc "Reports public-page identity and slug migration decisions"

  @moduledoc "Reports every public-page migration decision before the contract phase."

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    decisions = Alplus.PublicPages.Migration.report()
    Mix.shell().info("public-page decisions: #{length(decisions)}")
  end
end
