defmodule AlplusWeb.PublicPageComponents do
  @moduledoc "Shared branding and section navigation for public project pages."

  use Phoenix.Component
  use AlplusWeb, :verified_routes

  import AlplusWeb.CoreComponents, only: [logo: 1]

  attr :public_page, :map, required: true
  attr :header_id, :string, default: "public-page-header"
  attr :active, :atom, values: [:status, :changelog], required: true
  attr :status_path, :string, default: nil
  attr :changelog_path, :string, default: nil

  attr :postdeploy_owned?, :boolean,
    default: false,
    doc: "true only for a page PostDeploy itself publishes, from the vendor designation"

  slot :trailing

  @doc """
  The masthead every public project page opens with: the page owner's mark and
  name, the Status/Changelog navigation, and an optional trailing action such
  as Subscribe or the feed links.

  Identity follows ownership, never appearance. A page PostDeploy publishes
  wears the same marketing lockup the site header wears and links it home. A
  customer's page wears the customer's own logo, or a neutral initial when
  they have none, and never borrows PostDeploy's mark or links their name to
  PostDeploy.

  The masthead is chrome, not the page subject, so the page name is a plain
  element here. Each page keeps its own single `h1` for what the page answers.

  Below `sm` the identity takes the first row. The two local links and trailing
  action share a deliberate second row in the same order as keyboard focus, so
  a long customer title never pushes navigation off the page.
  """
  def public_page_masthead(assigns) do
    assigns = assign(assigns, :initial, project_initial(assigns.public_page.title))

    ~H"""
    <header
      id={@header_id}
      class="border-b border-border-subtle bg-surface-page px-5 sm:px-11"
    >
      <div class="mx-auto flex max-w-content flex-wrap items-center gap-x-5 gap-y-2 py-3 sm:min-h-16 sm:flex-nowrap sm:py-0">
        <.logo
          :if={@postdeploy_owned?}
          href={~p"/"}
          label="PostDeploy home"
          class="min-h-target-min w-full sm:w-auto"
        />
        <p :if={!@postdeploy_owned?} class="flex w-full min-w-0 items-center gap-2.5 sm:w-auto">
          <span class="flex size-[22px] shrink-0 items-center justify-center overflow-hidden rounded-mark bg-surface-inverse">
            <img
              :if={@public_page.logo_url}
              src={@public_page.logo_url}
              alt=""
              class="size-full object-cover"
            />
            <span :if={is_nil(@public_page.logo_url)} class="text-[10px] font-bold text-text-inverse">
              {@initial}
            </span>
          </span>
          <span
            id="public-page-title"
            title={@public_page.title}
            class="min-w-0 truncate font-public text-[15px] font-bold text-text-primary"
          >
            {@public_page.title}
          </span>
        </p>

        <.public_page_nav
          active={@active}
          status_path={@status_path}
          changelog_path={@changelog_path}
        />

        <div :if={@trailing != []} class="ml-auto flex shrink-0 items-center gap-2">
          {render_slot(@trailing)}
        </div>
      </div>
    </header>
    """
  end

  attr :active, :atom, values: [:status, :changelog], required: true
  attr :status_path, :string, default: nil
  attr :changelog_path, :string, default: nil

  @doc """
  The local navigation between a project's public Status and Changelog pages.

  It is the page's own second row below `sm`, so it never competes with the
  identity or the feed action for the first row's width.
  """
  def public_page_nav(assigns) do
    ~H"""
    <nav
      :if={@status_path || @changelog_path}
      id="public-page-navigation"
      aria-label="Project public pages"
      class="flex min-w-0 shrink-0 items-center gap-1"
    >
      <a
        :if={@status_path}
        id="public-page-status-link"
        href={@status_path}
        aria-current={if @active == :status, do: "page"}
        class={navigation_link_class(@active == :status)}
      >
        Status
      </a>
      <a
        :if={@changelog_path}
        id="public-page-changelog-link"
        href={@changelog_path}
        aria-current={if @active == :changelog, do: "page"}
        class={navigation_link_class(@active == :changelog)}
      >
        Changelog
      </a>
    </nav>
    """
  end

  @doc "Pill-shaped quiet action for a public page: Subscribe, feeds, back links."
  def public_action_class do
    "inline-flex min-h-target-min items-center gap-1.5 rounded-dot border border-border-public " <>
      "px-[15px] text-[13px] font-semibold text-text-secondary hover:bg-surface-sunken hover:text-text-primary"
  end

  @doc "Quiet public link with the minimum public touch target."
  def public_quiet_link_class do
    "inline-flex min-h-target-min items-center gap-1.5 text-[13px] font-semibold " <>
      "text-text-secondary hover:text-text-primary hover:underline"
  end

  attr :postdeploy_owned?, :boolean, required: true
  attr :class, :any, default: nil

  @doc """
  The one product link a customer's public page carries.

  A page PostDeploy publishes already links its own lockup home, so it renders
  nothing here rather than crediting itself twice.
  """
  def public_attribution(assigns) do
    ~H"""
    <p
      :if={!@postdeploy_owned?}
      class={["text-label font-medium text-text-tertiary", @class]}
    >
      Powered by
      <a
        href={~p"/"}
        class="inline-flex min-h-target-min items-center font-semibold text-text-secondary hover:text-text-primary hover:underline"
      >PostDeploy</a>
    </p>
    """
  end

  defp project_initial(title) when is_binary(title) do
    case String.trim(title) do
      "" -> "?"
      trimmed -> trimmed |> String.first() |> String.upcase()
    end
  end

  defp project_initial(_title), do: "?"

  @doc "Returns a canonical authenticated Public page route."
  def public_page_path(org_token, project_token, :status),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/public/status"

  def public_page_path(org_token, project_token, :changelog),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/public/changelog"

  def public_page_path(org_token, project_token, :settings),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/public/settings"

  defp navigation_link_class(true) do
    "inline-flex min-h-target-min min-w-target-min items-center justify-center rounded-dot " <>
      "bg-interactive-wash px-3 text-[13px] font-semibold text-interactive-strong"
  end

  defp navigation_link_class(false) do
    "inline-flex min-h-target-min min-w-target-min items-center justify-center rounded-dot " <>
      "px-3 text-[13px] font-semibold text-text-secondary hover:text-text-primary hover:underline"
  end
end
