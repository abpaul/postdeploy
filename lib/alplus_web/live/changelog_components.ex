defmodule AlplusWeb.ChangelogComponents do
  @moduledoc """
  Shared pieces for the Changelog dashboard screens: the section subnav,
  the entry status badge, source-kind helpers, and route helpers.

  Lives under `live/` because Slice D owns only `lib/alplus_web/live/`
  (issue #73 ownership map).
  """

  use AlplusWeb, :html

  @doc """
  The Entries and Activity switch, as a segmented control that lives **inside
  a panel header**, not as a second tab row under the public-page subnav.

  Changelog used to stack two full-width tab rows, so the screen opened with
  two competing navigations before any content. The public-page subnav is the
  page's one tab row; this control picks which view of the Changelog the panel
  below shows, which is what a segmented control is for (DESIGN.md, "Segmented
  control").

  Both segments navigate to their own route, so they are links carrying
  `aria-current`, never buttons carrying `aria-pressed`.
  """
  attr :org_token, :string, required: true
  attr :project_token, :string, required: true
  attr :active, :atom, required: true, values: [:entries, :activity]

  def changelog_subnav(assigns) do
    ~H"""
    <nav
      id="changelog-subnav"
      aria-label="Changelog sections"
      class="inline-flex rounded-dot bg-surface-sunken p-0.5"
    >
      <.link
        :for={{key, label} <- changelog_subnav_items()}
        id={"changelog-subnav-#{key}"}
        navigate={changelog_path(@org_token, @project_token, key)}
        aria-current={@active == key && "page"}
        class={[
          "inline-flex h-control-sm items-center whitespace-nowrap rounded-dot px-3.5 text-label font-semibold transition-colors duration-productive",
          if(@active == key,
            do: "bg-surface-raised text-text-primary shadow-segment",
            else: "text-text-tertiary hover:text-text-primary"
          )
        ]}
      >
        {label}
      </.link>
    </nav>
    """
  end

  defp changelog_subnav_items,
    do: [{:entries, "Entries"}, {:activity, "Activity"}]

  @doc """
  One badge per entry status, so draft, published, and archived render
  identically on every screen.
  """
  attr :status, :atom, required: true, values: [:draft, :published, :archived]

  def entry_status_badge(%{status: :draft} = assigns) do
    ~H"""
    <.status_badge tone="warning" label="Draft" />
    """
  end

  def entry_status_badge(%{status: :published} = assigns) do
    ~H"""
    <.status_badge tone="success" label="Published" />
    """
  end

  def entry_status_badge(%{status: :archived} = assigns) do
    ~H"""
    <.status_badge tone="neutral" icon="hero-archive-box" label="Archived" />
    """
  end

  @doc "Heroicon name for one source-reference kind."
  def source_kind_icon("pull_request"), do: "hero-code-bracket-square"
  def source_kind_icon("issue"), do: "hero-ticket"
  def source_kind_icon("release"), do: "hero-tag"
  def source_kind_icon("deployment"), do: "hero-rocket-launch"
  def source_kind_icon("commit"), do: "hero-code-bracket"
  def source_kind_icon(_other), do: "hero-link"

  @doc "Human label for one source-reference kind."
  def source_kind_label("pull_request"), do: "Pull request"
  def source_kind_label("issue"), do: "Issue"
  def source_kind_label("release"), do: "Release"
  def source_kind_label("deployment"), do: "Deployment"
  def source_kind_label("commit"), do: "Commit"
  def source_kind_label(_other), do: "Link"

  @doc "Path to one Changelog dashboard section."
  def changelog_path(org_token, project_token, :entries),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/public/changelog/entries"

  def changelog_path(org_token, project_token, :settings),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/public/settings"

  def changelog_path(org_token, project_token, :activity),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/public/changelog/activity"

  @doc "Path to one entry's review screen."
  def entry_path(org_token, project_token, entry_id),
    do:
      ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/public/changelog/entries/#{entry_id}"

  @doc """
  Public path for a changelog slug. Built as a plain string because the
  public routes belong to the controller slice of issue #73 and compile
  independently of this one.
  """
  def public_changelog_path(public_slug), do: "/status/#{public_slug}/changelog"
end
