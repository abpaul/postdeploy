defmodule Alplus.Release do
  @moduledoc """
  Release tasks that run outside the web process.

  Migrations run as a dedicated task so deployments can fail before a new web
  process receives traffic.
  """

  @app :alplus

  def migrate do
    load_app()

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Publishes marketing content.

  Runs on every container boot, which is safe and deliberate:
  content seeds look up stable identities before creating rows.

  Failures are logged and swallowed. A seed problem must not crash the
  container and take the whole site down.
  """
  def seed do
    load_app()

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _result, _apps} = Ecto.Migrator.with_repo(repo, fn _repo -> run_seeds() end)
    end
  end

  defp run_seeds do
    Alplus.Content.Seeds.run()
    :ok
  rescue
    error ->
      require Logger

      Logger.error("""
      marketing content seeding failed: #{Exception.message(error)}

      The app will still boot. Content-backed pages (/pricing, /monitoring,
      /alternatives/*, guides) will 404 until this succeeds. Re-run with:
      bin/alplus eval 'Alplus.Release.seed()'
      """)

      :error
  end

  defp load_app do
    Application.load(@app)
  end
end
