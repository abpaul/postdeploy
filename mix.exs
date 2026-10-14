defmodule Alplus.MixProject do
  use Mix.Project

  def project do
    [
      app: :alplus,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev,
      test_coverage: [tool: ExCoveralls],
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "priv/plts/core",
        plt_local_path: "priv/plts/local"
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Alplus.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test,
        check: :test,
        coveralls: :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        dialyzer: :test
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  # `dev/` holds tooling that must never ship in a release. `Alplus.Seo.Audit`
  # is a CI/developer command that parses HTML with `lazy_html`, a
  # [:dev, :test] dependency, so compiling it into :prod produced "module
  # LazyHTML is not available" warnings and left a module in the release that
  # would raise if anything called it. The mix task and its tests live in
  # :dev/:test only.
  defp elixirc_paths(:test), do: ["lib", "dev", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:bcrypt_elixir, "~> 3.0"},
      {:picosat_elixir, "~> 0.2"},
      {:oban, "~> 2.0"},
      {:hammer, "~> 7.4"},
      {:stripity_stripe, "~> 3.3"},
      {:ex_aws, "~> 2.7"},
      {:ex_aws_s3, "~> 2.5"},
      {:ash_state_machine, "~> 0.2"},
      {:ash_cloak, "~> 0.1"},
      {:cloak, "~> 1.1"},
      {:ash_archival, "~> 2.0"},
      {:ash_oban, "~> 0.8"},
      {:ash_authentication_phoenix, "~> 2.0"},
      {:ash_authentication, "~> 4.0"},
      {:ash_phoenix, "~> 2.0"},
      {:ash_postgres, "~> 2.0"},
      # Spark.Formatter needs it; without it `mix format` raises on every DSL file.
      {:sourceror, "~> 1.12", only: [:dev, :test], runtime: false},
      # Changelog Markdown is user-authored. MDEx renders and sanitizes in one
      # maintained parser, so no caller can forget the safety pass. It is the
      # only path from stored Markdown to public HTML.
      {:mdex, "~> 0.13.5"},
      # ExMCP serves the shared MCP endpoint. It replaced anubis_mcp because
      # anubis tops out at protocol 2025-11-25 while ExMCP negotiates
      # 2026-07-28 as well, and issue #73 requires both generations.
      {:ex_mcp, "~> 1.0"},
      # ExMCP requires plug_cowboy for its standalone server, which this app
      # never starts: `ExMCP.HttpPlug` is mounted inside the Bandit endpoint.
      # It stays a normal dependency because ExMCP's own `.app` lists it, so
      # restricting it to dev and test fails the release with "Could not find
      # application :plug_cowboy".
      #
      # Consequence: Cowlib 2.19.0 ships in the release and carries
      # EEF-CVE-2026-43966, an HTTP response splitting issue in
      # `cow_http_struct_hd:escape_string/2`. It is the newest release and has
      # no patch. `mix hex.audit` reports it. The affected code is never
      # reached, because Cowboy is never started and Bandit serves every
      # request. Re-check for a patched Cowlib before the next dependency bump.
      # Already resolved transitively, declared directly because
      # Alplus.Changelog.FrontMatter depends on its duplicate-key behavior.
      {:yaml_elixir, "~> 2.12"},
      {:ash, "~> 3.0"},
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      # Also available in :dev so `mix alplus.seo.audit` can parse the real
      # rendered HTML. Never a :prod dependency.
      {:lazy_html, ">= 0.1.0", only: [:dev, :test]},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:gen_smtp, "~> 1.2"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      # Dogfooding: this app reports its own crashes with the official Sentry
      # SDK through the public `/api/:project_id/envelope` endpoint, the same
      # path a customer uses.
      {:sentry, "~> 13.5"},
      # Drives test/alplus_web/e2e/sdk_ingest_e2e_test.exs through `/e/errors`.
      {:postdeploy_sdk, "~> 0.2.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ash.setup", "assets.setup", "assets.build", "run priv/repo/seeds.exs"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ash.setup --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind alplus", "esbuild alplus"],
      "assets.deploy": [
        "tailwind alplus --minify",
        "esbuild alplus --minify",
        "phx.digest"
      ],
      # Fast local gate, run before every commit (seconds). Excludes dialyzer:
      # PLT build/check is slow and belongs in `check` (CI / on-demand) instead.
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "credo",
        "sobelow --strict --private --exit --threshold low --skip",
        "deps.audit",
        "format",
        "test"
      ],
      # Full gate for CI / on-demand review. Includes dialyzer (slow PLT build).
      check: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo",
        "sobelow --strict --private --exit --threshold low --skip",
        "deps.audit",
        "dialyzer",
        "test"
      ]
    ]
  end
end
