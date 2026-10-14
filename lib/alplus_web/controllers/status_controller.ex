defmodule AlplusWeb.StatusController do
  use AlplusWeb, :controller

  alias Alplus.Changelog.Public, as: PublicChangelog
  alias Alplus.Status.RateLimiter
  alias Alplus.Status
  alias AlplusWeb.Marketing.Seo

  def show(conn, %{"status_slug" => slug}) do
    case load_snapshot(slug) do
      {:ok, snapshot} ->
        maybe_redirect_or(conn, snapshot, slug, "", fn conn ->
          conn
          |> Seo.assign_seo(
            title: snapshot.public_page.title,
            description: "Current status and service health for #{snapshot.public_page.title}.",
            path: "/status/#{snapshot.public_page.public_slug}",
            measure_self_tracking: false
          )
          |> cache_headers()
          |> render(:show,
            flash: %{},
            snapshot: snapshot,
            changelog: load_changelog(snapshot.public_page.public_slug)
          )
        end)

      {:error, {:rate_limited, retry_after}} ->
        rate_limited(conn, retry_after)

      _ ->
        raise AlplusWeb.NotFoundError
    end
  end

  def history(conn, %{"status_slug" => slug}) do
    case load_snapshot(slug) do
      {:ok, snapshot} ->
        maybe_redirect_or(conn, snapshot, slug, "/history", fn conn ->
          conn
          |> Seo.assign_seo(
            title: "#{snapshot.public_page.title} history",
            description:
              "90-day status history and incident timeline for #{snapshot.public_page.title}.",
            path: "/status/#{snapshot.public_page.public_slug}/history",
            measure_self_tracking: false
          )
          |> cache_headers()
          |> render(:history, flash: %{}, snapshot: snapshot)
        end)

      {:error, {:rate_limited, retry_after}} ->
        rate_limited(conn, retry_after)

      _ ->
        raise AlplusWeb.NotFoundError
    end
  end

  def feed(conn, %{"status_slug" => slug}) do
    case load_snapshot(slug) do
      {:ok, snapshot} ->
        maybe_redirect_or(conn, snapshot, slug, "/feed.xml", fn conn ->
          body = AlplusWeb.StatusHTML.feed_xml(snapshot)

          conn
          |> cache_headers()
          |> put_resp_content_type("application/rss+xml", nil)
          |> send_resp(:ok, body)
        end)

      {:error, {:rate_limited, retry_after}} ->
        rate_limited(conn, retry_after)

      _ ->
        raise AlplusWeb.NotFoundError
    end
  end

  def embed(conn, %{"status_slug" => slug}) do
    case load_snapshot(slug) do
      {:ok, snapshot} ->
        maybe_redirect_or(conn, snapshot, slug, "/embed", fn conn ->
          conn
          |> cache_headers()
          |> put_root_layout(false)
          |> render(:embed, snapshot: snapshot)
        end)

      {:error, {:rate_limited, retry_after}} ->
        rate_limited(conn, retry_after)

      _ ->
        raise AlplusWeb.NotFoundError
    end
  end

  def embed_json(conn, %{"status_slug" => slug}) do
    case load_snapshot(slug) do
      {:ok, snapshot} ->
        maybe_redirect_or(conn, snapshot, slug, "/embed.json", fn conn ->
          conn
          |> cache_headers()
          |> json(json_snapshot(snapshot))
        end)

      {:error, {:rate_limited, retry_after}} ->
        rate_limited(conn, retry_after)

      _ ->
        raise AlplusWeb.NotFoundError
    end
  end

  defp load_snapshot(slug) do
    with {:ok, %{page: page}} <- Status.resolve(slug),
         :ok <- rate_limit(page.id) do
      Status.load_public(slug)
    end
  end

  defp maybe_redirect_or(conn, snapshot, requested_slug, suffix, render_fun) do
    canonical_slug = snapshot.public_page.public_slug

    if canonical_slug != requested_slug do
      conn
      |> put_status(:moved_permanently)
      |> redirect(to: "/status/#{canonical_slug}#{suffix}")
    else
      render_fun.(conn)
    end
  end

  defp rate_limit(page_id) do
    case RateLimiter.check(page_id) do
      :ok -> :ok
      {:error, retry_after} -> {:error, {:rate_limited, retry_after}}
    end
  end

  defp rate_limited(conn, retry_after) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> send_resp(429, "Too Many Requests")
  end

  defp cache_headers(conn) do
    put_resp_header(
      conn,
      "cache-control",
      "public, max-age=30, stale-while-revalidate=60, stale-if-error=86400"
    )
  end

  defp load_changelog(slug) do
    case PublicChangelog.load_for_public_slug(slug, limit: 3) do
      {:ok, public} -> %{available?: true, entries: public.entries}
      {:error, _reason} -> %{available?: false, entries: []}
    end
  end

  defp json_snapshot(snapshot) do
    %{
      status: status_value(snapshot.status),
      components:
        Enum.map(snapshot.components, fn component ->
          %{name: component.name, status: status_value(component.status)}
        end)
    }
  end

  defp status_value(:operational), do: "operational"
  defp status_value(:degraded), do: "degraded"
  defp status_value(:partial_outage), do: "partial_outage"
  defp status_value(:major_outage), do: "major_outage"
  defp status_value(:maintenance), do: "maintenance"
  defp status_value(:up), do: "up"
  defp status_value(:down), do: "down"
  defp status_value(:unknown), do: "unknown"
end
