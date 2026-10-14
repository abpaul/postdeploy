defmodule AlplusWeb.WebsiteHealthCheckController do
  use AlplusWeb, :controller

  require Ash.Query

  alias Alplus.Billing.Package
  alias Alplus.Growth.HealthCheck
  alias Alplus.Monitoring.{AnonymousProbe, MonitorCreator, MonitorFormAttrs, MonitorWorker}
  alias AlplusWeb.Marketing.Seo
  alias AlplusWeb.WebsiteHealthCheck.{Handoff, Page}

  plug :redact_query

  @path Page.path()

  @doc """
  Starts the monitor handoff from the result the LiveView is showing.

  `AlplusWeb.WebsiteHealthCheckLive` runs the check over the socket, so the
  draft cannot be written there: a LiveView never owns the session. This
  action re-validates the address it is given, stores the draft and the
  journey id, and sends the visitor to registration or to the confirm step.
  """
  def monitor(conn, params) do
    url = stringify(params["target_url"])
    keyword = params["keyword"] |> stringify() |> blank_to_nil()

    with {:ok, uri} <- AnonymousProbe.Url.parse(url),
         {:ok, keyword} <- AnonymousProbe.Url.keyword(keyword) do
      conn
      |> Handoff.put_draft(AnonymousProbe.Url.display(uri), keyword)
      |> Handoff.put_journey_id(params["journey_id"])
      |> put_session(:return_to, Handoff.continue_path())
      |> redirect(to: monitor_destination(conn))
    else
      _ ->
        conn
        |> put_flash(:error, "Run a check first, then start continuous monitoring.")
        |> redirect(to: @path)
    end
  end

  def continue(conn, _params) do
    case Handoff.peek(conn) do
      :missing ->
        redirect(conn, to: @path)

      :expired ->
        conn
        |> Handoff.delete()
        |> put_flash(:error, "That check expired after 24 hours. Run it again.")
        |> redirect(to: @path)

      {:ok, draft} ->
        continue_with_draft(conn, conn.assigns[:current_user], draft)
    end
  end

  def confirm(conn, _params) do
    user = conn.assigns[:current_user]

    with %{confirmed_at: confirmed} when not is_nil(confirmed) <- user,
         {:ok, draft} <- Handoff.peek(conn),
         {:ok, org, project, scope} <- workspace(user),
         {:ok, created} <- create_monitor(draft, org, project, scope) do
      {conn, journey_id} = Handoff.journey_id(conn)
      HealthCheck.record(journey_id, "configured", user.id)
      check = first_check(created.monitor, scope)

      conn =
        if check do
          HealthCheck.record(journey_id, "activated", user.id)
          conn
        else
          conn
        end

      conn
      |> Handoff.delete()
      |> assign_page()
      |> assign(:draft, draft)
      |> assign(:monitor, created.monitor)
      |> assign(:check, check)
      |> assign(:org, org)
      |> assign(:project, project)
      |> render(:activated)
    else
      _ ->
        conn
        |> Handoff.delete()
        |> redirect(to: @path)
    end
  end

  defp continue_with_draft(conn, nil, _draft) do
    conn
    |> put_session(:return_to, Handoff.continue_path())
    |> redirect(to: ~p"/register")
  end

  defp continue_with_draft(conn, %{confirmed_at: nil}, _draft) do
    conn
    |> put_session(:return_to, Handoff.continue_path())
    |> put_flash(:info, "Confirm your email before creating a monitor.")
    |> redirect(to: ~p"/dashboard")
  end

  defp continue_with_draft(conn, user, draft), do: continue_workspace(conn, user, draft)

  defp continue_workspace(conn, user, draft) do
    scope = Alplus.Scope.for_user(user.id)

    case Alplus.Orgs.list_organizations!(actor: scope) do
      [] ->
        conn
        |> put_session(:return_to, Handoff.continue_path())
        |> redirect(to: ~p"/dashboard/orgs/new")

      [org] ->
        {:ok, scope} = Alplus.Orgs.build_scope(scope, org.id)
        projects = Alplus.Projects.list_projects_for_org!(org.id, actor: scope)

        case projects do
          [] ->
            conn
            |> put_session(:return_to, Handoff.continue_path())
            |> redirect(to: ~p"/dashboard/orgs/#{org.public_token}/projects")

          _ ->
            conn
            |> assign_page()
            |> assign(:draft, draft)
            |> assign(:org, org)
            |> render(:confirm)
        end

      _orgs ->
        conn
        |> put_session(:return_to, Handoff.continue_path())
        |> redirect(to: ~p"/dashboard")
    end
  end

  defp workspace(user) do
    scope = Alplus.Scope.for_user(user.id)

    case Alplus.Orgs.list_organizations!(actor: scope) do
      [org] ->
        {:ok, scope} = Alplus.Orgs.build_scope(scope, org.id)

        case Alplus.Projects.list_projects_for_org!(org.id, actor: scope) do
          [project | _] ->
            scope = Alplus.Scope.put_project(scope, project.id)
            {:ok, org, project, scope}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp create_monitor(draft, org, _project, scope) do
    type = if draft.keyword, do: "keyword", else: "http"
    interval = interval_seconds(org.id)
    name = monitor_name(draft.url)

    config = %{
      "url" => draft.url,
      "keyword" => draft.keyword,
      "interval_seconds" => interval
    }

    with {:ok, monitor_attrs, config_attrs} <-
           MonitorFormAttrs.monitor_create_attrs(
             %{"name" => name, "type" => type},
             config,
             scope
           ) do
      MonitorCreator.create(monitor_attrs, config_attrs, scope)
    end
  rescue
    _ -> {:error, :create_failed}
  end

  defp first_check(monitor, scope) do
    _ = start_worker(monitor.id)

    try do
      MonitorWorker.run_now(monitor.id)
    catch
      :exit, _ -> :error
    end

    case Alplus.Monitoring.MonitorCheck
         |> Ash.Query.filter(monitor_id == ^monitor.id)
         |> Ash.Query.sort(checked_at: :desc)
         |> Ash.Query.limit(1)
         |> Ash.read(actor: scope) do
      {:ok, [check | _]} -> check
      _ -> nil
    end
  end

  defp start_worker(monitor_id) do
    case MonitorWorker.start_link(monitor_id) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      _ -> :ok
    end
  end

  # One package, one interval floor, so this needs no entitlement read.
  defp interval_seconds(_org_id), do: Package.limit(:min_check_interval_seconds)

  defp monitor_name(url) do
    host =
      case URI.parse(url) do
        %URI{host: host} when is_binary(host) -> host
        _ -> "site"
      end

    host |> String.slice(0, 200)
  end

  defp monitor_destination(conn) do
    if conn.assigns[:current_user], do: Handoff.continue_path(), else: ~p"/register"
  end

  defp assign_page(conn) do
    conn
    |> Seo.assign_seo(Page.seo_opts())
    |> assign(:breadcrumbs, Page.breadcrumbs())
  end

  defp redact_query(conn, _opts) do
    %{conn | query_string: ""}
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(_), do: ""

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
