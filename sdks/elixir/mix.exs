defmodule PostDeploy.MixProject do
  use Mix.Project

  @version "0.3.0"
  # The source lives in the private PostDeploy monorepo, so the published
  # package points at the product site rather than a repository URL.
  @homepage "https://postdeploy.dev"
  @setup_guide "https://postdeploy.dev/docs/observe/elixir"

  def project do
    [
      app: :postdeploy_sdk,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: true, threshold: 99.9],
      deps: deps(),
      description: "PostDeploy instrumentation for Elixir and Phoenix.",
      package: package(),
      docs: [
        extras: ["README.md"],
        main: "readme",
        filter_modules: ~r/^PostDeploy(\.Plug|\.Test)?$/
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:bypass, "~> 2.1", only: :test},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"Homepage" => @homepage, "Setup guide" => @setup_guide},
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end
end
