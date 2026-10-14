defmodule Mix.Tasks.Alplus.Seo.Audit do
  @shortdoc "Audits every public route for SEO defects"

  @moduledoc """
  Renders every public route through the application and reports SEO defects:
  missing or duplicate titles, descriptions and canonicals, missing H1s,
  invalid structured data, broken internal links, orphan pages, and images
  without alt text.

      mix alplus.seo.audit

  Exits non-zero when any `:error` finding is present, so it is usable as a
  CI gate. Warnings are reported but do not fail the run.

  The task renders through `Phoenix.ConnTest`-style calls against the
  endpoint rather than over the network, so it needs no running server and
  audits exactly the HTML the app produces.
  """

  use Mix.Task

  alias Alplus.Seo.Audit

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    # An unseeded database has no content rows, so the audit would find
    # nothing and "pass". That is the most dangerous possible result in CI,
    # because it looks identical to a clean site. Refuse instead.
    case Audit.public_paths() do
      [] ->
        Mix.raise(
          "no public routes found. Seed marketing content first: " <>
            "mix run priv/repo/seeds.exs"
        )

      paths ->
        findings = Audit.run(&fetch/1)

        Mix.shell().info(Audit.format(findings))

        errors = Enum.count(findings, &(&1.severity == :error))

        if errors > 0 do
          Mix.shell().error(
            "SEO audit failed: #{errors} error(s) across #{length(paths)} routes."
          )

          exit({:shutdown, 1})
        end
    end
  end

  # Calls the endpoint directly with a minimal conn. This is the same path a
  # browser request takes, minus the socket.
  defp fetch(path) do
    conn =
      Plug.Test.conn(:get, path)
      |> Plug.Conn.put_private(:phoenix_recycled, true)
      |> AlplusWeb.Endpoint.call(AlplusWeb.Endpoint.init([]))

    %{status: conn.status, body: conn.resp_body}
  end
end
