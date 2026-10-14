defmodule AlplusWeb.OrgContext do
  @moduledoc """
  Shared `mount/3` helper for every LiveView under
  `/dashboard/orgs/:org_token/...` (ARCHITECTURE.md §4, §9).

  Resolves `org_token` to a scoped `Alplus.Scope` via `Alplus.Orgs.build_scope/2`
  (404 for a cross-tenant id, never 403 — ARCHITECTURE.md §4), and loads the
  actor's org list for the shell's switcher. Both reads are cheap,
  indexed, actor-scoped lookups, run unconditionally (not gated by
  `connected?/1`) so the very first, disconnected render already answers
  404 for a cross-tenant id and already has the nav populated — the same
  tradeoff `AlplusWeb.ProjectsLive` documents for its own membership
  lookup.
  """

  import Phoenix.Component, only: [assign: 3]
  use AlplusWeb, :verified_routes

  @spec mount(String.t(), Phoenix.LiveView.Socket.t(), keyword()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(org_token, socket, opts) when is_binary(org_token) do
    socket =
      socket
      |> assign_org_context(org_token)
      |> assign(:page_title, Keyword.fetch!(opts, :page_title))
      |> assign(:active_nav, Keyword.fetch!(opts, :active))
      # `AlplusWeb.ConnectGate` sets this to true before the view mounts on a
      # project screen. `assign_new/3` leaves that answer alone and only
      # supplies the default for an org screen the gate never ran on.
      |> Phoenix.Component.assign_new(:agent_connected?, fn -> false end)

    {:ok, socket}
  end

  @doc """
  Assigns the org scope, switcher list and sidebar projects for
  `org_token`, raising `AlplusWeb.NotFoundError` for an unknown or
  cross-tenant reference.

  Idempotent: a socket already carrying the same organization is returned
  untouched, so `AlplusWeb.ConnectGate` can resolve org and project
  before the view mounts without any LiveView paying for a second set of
  lookups.
  """
  @spec assign_org_context(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def assign_org_context(socket, org_token) when is_binary(org_token) do
    if already_assigned?(socket, org_token) do
      socket
    else
      resolve_org_context(socket, org_token)
    end
  end

  # The legacy primary-key URL form (see `organization_for_reference/2`)
  # must also count as "already assigned", or a gated mount would resolve
  # the org twice for a stale bookmark.
  defp already_assigned?(socket, org_token) do
    case socket.assigns[:org] do
      nil -> false
      org -> org.public_token == org_token or org.id == org_token
    end
  end

  defp resolve_org_context(socket, org_token) do
    scope = Alplus.Scope.for_user(socket.assigns.current_user.id)

    case organization_for_reference(scope, org_token) do
      {:ok, org} ->
        {:ok, scope} = Alplus.Orgs.build_scope(scope, org.id)
        Logger.metadata(org_id: org.id)

        organizations =
          Alplus.Orgs.list_organizations!(
            actor: scope,
            query: Ash.Query.sort(Alplus.Orgs.Organization, inserted_at: :desc)
          )

        # Every org-level page (Projects, Team, Billing, Settings)
        # keeps the org's projects (and their Monitor/Measure/Observe links)
        # visible in the sidebar, not only project-scoped pages (issue #29
        # follow-up). One cheap, actor-scoped, indexed read, and the only
        # project list a mount needs: `project_for_token!/2` resolves out of
        # this assign instead of repeating the query.
        nav_projects =
          Alplus.Projects.list_projects_for_org!(org.id,
            actor: scope,
            query: Ash.Query.sort(Alplus.Projects.Project, inserted_at: :desc)
          )

        socket
        |> assign(:scope, scope)
        |> assign(:org_id, org.id)
        |> assign(:org_token, org.public_token)
        |> assign(:org, org)
        |> assign(:organizations, organizations)
        |> assign(:nav_projects, nav_projects)

      {:error, :not_found} ->
        raise AlplusWeb.NotFoundError
    end
  end

  # Existing bookmarks may still contain a primary key while this public-token
  # URL migration rolls out. Resolve that legacy form only after the token
  # lookup fails; all links emitted by the console use `public_token`.
  defp organization_for_reference(scope, reference) do
    case Alplus.Orgs.get_organization_by_public_token(reference, actor: scope) do
      {:ok, organization} ->
        {:ok, organization}

      {:error, _} ->
        with {:ok, scoped} <- Alplus.Orgs.build_scope(scope, reference),
             organizations <- Alplus.Orgs.list_organizations!(actor: scoped),
             organization when not is_nil(organization) <-
               Enum.find(organizations, &(&1.id == reference)) do
          {:ok, organization}
        else
          _ -> {:error, :not_found}
        end
    end
  end

  @doc """
  Resolves an active project public token inside the organization already
  established by `mount/3` (or by `assign_org_context/2`), out of the
  `nav_projects` assign that resolution already loaded. A token from
  another organization, an archived project, and an unknown token
  deliberately share the same 404 outcome.
  """
  @spec project_for_token!(Phoenix.LiveView.Socket.t(), String.t()) :: struct()
  def project_for_token!(socket, project_token) when is_binary(project_token) do
    case Enum.find(socket.assigns.nav_projects, &(&1.public_token == project_token)) do
      nil -> raise AlplusWeb.NotFoundError
      project -> project
    end
  end

  @doc "`true` for `owner`/`admin` — the two roles that manage org resources (ARCHITECTURE.md §4)."
  @spec can_manage?(Alplus.Scope.t()) :: boolean()
  def can_manage?(%Alplus.Scope{role: role}), do: role in ["owner", "admin"]

  @doc "`true` only for `owner` — ownership transfer and last-owner actions (ARCHITECTURE.md §4)."
  @spec owner?(Alplus.Scope.t()) :: boolean()
  def owner?(%Alplus.Scope{role: role}), do: role == "owner"
end
