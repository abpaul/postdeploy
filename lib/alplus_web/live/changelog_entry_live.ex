defmodule AlplusWeb.ChangelogEntryLive do
  @moduledoc """
  Read-only analysis of one agent-written Changelog entry.

  Agents own the document and its lifecycle through the shared contract. This
  surface renders the sanitized document, publication state, evidence,
  revisions, audit activity, and the frozen public link.
  """

  use AlplusWeb, :live_view

  import AlplusWeb.DashboardComponents
  import AlplusWeb.ChangelogComponents

  alias Alplus.Changelog
  alias Alplus.Changelog.{ActivityEvent, Markdown, SourceReference}
  alias Alplus.Mcp
  alias Alplus.PublicPages

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  require Ash.Query

  @impl true
  def mount(%{"org_token" => org_token, "project_token" => project_token}, _session, socket) do
    with {:ok, socket} <-
           AlplusWeb.OrgContext.mount(org_token, socket,
             page_title: "Changelog",
             active: :public
           ) do
      project = AlplusWeb.OrgContext.project_for_token!(socket, project_token)
      scope = Alplus.Scope.put_project(socket.assigns.scope, project.id)

      {:ok,
       socket
       |> assign(:scope, scope)
       |> assign(:project, project)
       |> assign(:public_page, nil)
       |> assign(:public_page_error, nil)
       |> assign(:publication, publication_state(nil, %{status: :draft}))
       |> assign(:preview_error, nil)
       |> assign(:oauth_grant?, false)
       |> assign(:activity, [])}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = load_entry(socket, params["entry_handle"])
    {:noreply, assign_viewing_revision(socket, params["revision"])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_shell
      agent_connected?={@agent_connected?}
      flash={@flash}
      org={@org}
      organizations={@organizations}
      scope={@scope}
      current_user={@current_user}
      active={:changelog}
      page_title={@entry.title}
      nav_project={@project}
      nav_projects={@nav_projects}
    >
      <.console_page id="changelog-entry-page">
        <div id="changelog-entry" class="flex flex-col gap-4">
          <.dashboard_header>
            <:leading>
              <.entry_status_badge status={@entry.status} />
              <p
                :if={@entry.public_slug}
                id="entry-slug"
                class="break-all font-mono text-data text-text-secondary"
              >
                {@entry.public_slug}
              </p>
              <p
                id="entry-external-id"
                class="max-w-[16rem] truncate font-mono text-label text-text-tertiary"
                title={@entry.external_id}
              >
                {@entry.external_id}
              </p>
              <p id="entry-publication" class="text-data text-text-tertiary">
                <%= if @entry.published_at do %>
                  Published <.timestamp at={@entry.published_at} />
                <% else %>
                  Not published
                <% end %>
              </p>
            </:leading>
          </.dashboard_header>
          <.alert
            :if={@public_page_error}
            id="entry-public-page-error"
            kind="error"
            title="Public page unavailable"
            message={@public_page_error}
          />
          <.data_panel id="entry-publication-state" title="Publication" padded>
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div class="flex min-w-0 flex-wrap items-center gap-2">
                <.status_badge tone={@publication.tone} label={@publication.label} />
                <p id="entry-publication-message" class="text-body text-text-secondary">
                  {@publication.message}
                </p>
              </div>
              <a
                :if={@publication.url}
                id="entry-public-url"
                href={@publication.url}
                target="_blank"
                rel="noopener"
                class="inline-flex min-h-target-min items-center text-data font-medium text-interactive-strong underline underline-offset-2 hover:text-text-primary"
              >
                Open public entry
              </a>
            </div>
          </.data_panel>
          <.first_run_card
            :if={agent_guidance?(@entry, @current_revision, @viewing_revision, @sources)}
            id="entry-agent-guidance"
            title={agent_guidance(@entry, @current_revision, @viewing_revision, @sources).title}
            description={
              agent_guidance(@entry, @current_revision, @viewing_revision, @sources).description
            }
            task={agent_guidance(@entry, @current_revision, @viewing_revision, @sources).task}
            state={if @oauth_grant?, do: :awaiting_evidence, else: :not_connected}
            action_href={~p"/dashboard/orgs/#{@org_token}/projects/#{@project.public_token}/connect"}
          />
          <.alert
            :if={@preview_error}
            id="entry-preview-error"
            kind="error"
            title="Preview unavailable"
            message={@preview_error}
          />
          <.data_panel
            id="entry-document"
            title="Document"
            description="Rendered Markdown from the current agent revision."
          >
            <%= cond do %>
              <% is_nil(@current_revision) -> %>
                <div id="entry-no-revision" class="p-4 text-data text-text-secondary">
                  No revision is available for this entry.
                </div>
              <% @viewing_revision -> %>
                <p
                  id="entry-revision-banner"
                  class="border-b border-border-default bg-surface-sunken px-5 py-3 text-data text-text-secondary"
                >
                  You view revision {@viewing_revision.revision_number}. This view is read only.
                  <.link
                    patch={entry_path(@org_token, @project.public_token, @entry.id)}
                    id="entry-revision-back"
                    class="font-medium text-text-primary underline underline-offset-2 hover:text-interactive-strong-hover"
                  >
                    Back to the current revision
                  </.link>
                </p>
                <div id="entry-revision-rendered" class="changelog-preview p-4">
                  {raw(Markdown.render(@viewing_revision.markdown))}
                </div>
              <% true -> %>
                <div id="entry-preview" class="changelog-preview p-4">{raw(@preview_html)}</div>
            <% end %>
          </.data_panel>
          <.data_panel
            id="entry-evidence"
            title="Evidence"
            description="Source references attached by the agent."
          >
            <ul class="divide-y divide-border-default">
              <li
                :for={source <- @sources}
                id={"entry-source-#{source.id}"}
                class="flex flex-wrap items-center justify-between gap-x-6 gap-y-2 px-4 py-3 sm:px-5"
              >
                <div class="flex min-w-0 items-center gap-2.5">
                  <.icon
                    name={source_kind_icon(source.kind)}
                    class="size-4 shrink-0 text-text-tertiary"
                  />
                  <a
                    href={source.url}
                    target="_blank"
                    rel="noopener"
                    class="min-w-0 truncate text-body font-medium text-text-primary hover:text-interactive-strong-hover"
                    title={source.url}
                  >{source.label || source.url}</a>
                  <span class="text-data text-text-tertiary">({source_kind_label(source.kind)})</span>
                </div>
                <.timestamp at={source.inserted_at} class="text-data tabular-nums text-text-tertiary" />
              </li>
              <li
                :if={@sources == []}
                id="entry-evidence-none"
                class="px-4 py-5 text-data text-text-secondary sm:px-5"
              >
                No evidence yet. The agent must attach source references before release.
              </li>
            </ul>
          </.data_panel>
          <.data_panel id="entry-revisions" title="Revisions">
            <ul class="divide-y divide-border-default">
              <li
                :for={rev <- @revisions}
                id={"entry-revision-#{rev.id}"}
                class="flex flex-wrap items-center justify-between gap-x-6 gap-y-2 px-4 py-3 sm:px-5"
              >
                <div class="flex flex-wrap items-center gap-2.5">
                  <.link
                    patch={entry_path(@org_token, @project.public_token, @entry.id) <> "?revision=#{rev.revision_number}"}
                    id={"view-revision-#{rev.revision_number}"}
                    class="text-body font-medium text-text-primary hover:text-interactive-strong-hover"
                  >
                    Revision {rev.revision_number}
                  </.link>
                  <.status_badge
                    :if={not is_nil(@current_revision) and rev.id == @current_revision.id}
                    tone="info"
                    label="Current"
                  />
                  <.status_badge :if={rev.status == :published} tone="success" label="Published" />
                </div>
                <.timestamp at={rev.inserted_at} class="text-data tabular-nums text-text-tertiary" />
              </li>
              <li
                :if={@revisions == []}
                id="entry-revisions-none"
                class="px-4 py-5 text-data text-text-secondary sm:px-5"
              >
                No revisions have been saved for this entry.
              </li>
            </ul>
          </.data_panel>
          <.data_panel
            id="entry-activity"
            title="Activity"
            description="Content-free audit events recorded for this entry."
          >
            <ul class="divide-y divide-border-default">
              <li
                :for={event <- @activity}
                id={"entry-activity-#{event.id}"}
                class="flex flex-wrap items-center justify-between gap-2 px-4 py-3 sm:px-5"
              >
                <span class="font-mono text-data text-text-primary">{event.event_type}</span>
                <.status_badge tone={activity_tone(event.outcome)} label={event.outcome} />
                <.timestamp at={event.inserted_at} class="text-data tabular-nums text-text-tertiary" />
              </li>
              <li
                :if={@activity == []}
                id="entry-activity-none"
                class="px-4 py-5 text-data text-text-secondary sm:px-5"
              >
                No activity has been recorded for this entry.
              </li>
            </ul>
          </.data_panel>
        </div>
      </.console_page>
    </.dashboard_shell>
    """
  end

  defp load_entry(socket, entry_handle) do
    scope = socket.assigns.scope

    case Changelog.get_entry(entry_handle, actor: scope) do
      {:ok, entry} ->
        {:ok, revisions} = Changelog.list_revisions(entry, actor: scope)
        current_revision = List.first(revisions)

        {preview_html, preview_error} =
          if current_revision do
            case Changelog.preview_entry(entry, actor: scope) do
              {:ok, html} -> {html, nil}
              {:error, _reason} -> {"", "The Markdown preview is unavailable."}
            end
          else
            {"", nil}
          end

        {public_page, public_page_error} = public_page(scope, socket.assigns.project.id)
        sources = sources(scope, entry.id)

        socket
        |> assign(:entry, entry)
        |> assign(:page_title, entry.title)
        |> assign(:public_page, public_page)
        |> assign(:public_page_error, public_page_error)
        |> assign(:revisions, revisions)
        |> assign(:current_revision, current_revision)
        |> assign(:sources, sources)
        |> assign(:preview_html, preview_html)
        |> assign(:preview_error, preview_error)
        |> assign(:publication, publication_state(public_page, entry))
        |> assign(:oauth_grant?, oauth_grant?(scope))
        |> assign(:activity, activity(scope, entry.id))

      {:error, _reason} ->
        raise AlplusWeb.NotFoundError
    end
  end

  defp assign_viewing_revision(socket, revision_param) do
    viewing =
      with number when is_binary(number) <- revision_param,
           {number, ""} <- Integer.parse(number),
           %{} = revision <-
             Enum.find(socket.assigns.revisions, &(&1.revision_number == number)) do
        revision
      else
        _other -> nil
      end

    assign(socket, :viewing_revision, viewing)
  end

  defp sources(scope, entry_id) do
    SourceReference
    |> Ash.Query.for_read(:for_entry, %{entry_id: entry_id}, actor: scope)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(200)
    |> Ash.read!(actor: scope)
  end

  defp activity(scope, entry_id) do
    ActivityEvent
    |> Ash.Query.filter(entry_id == ^entry_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(100)
    |> Ash.read!(actor: scope)
  end

  defp oauth_grant?(scope) do
    query =
      Mcp.OAuthGrant
      |> Ash.Query.filter(org_id == ^scope.org_id and project_id == ^scope.project_id)
      |> Ash.Query.limit(1)

    # list/1 is owner/admin; connection evidence is member-readable.
    case Mcp.list_oauth_grants(query: query, actor: scope, authorize?: false) do
      {:ok, grants} -> grants != []
      {:error, _} -> false
    end
  end

  defp public_page(scope, project_id) do
    case PublicPages.get_for_project(scope, project_id) do
      {:ok, public_page} -> {public_page, nil}
      {:error, :not_found} -> {nil, nil}
      {:error, _reason} -> {nil, "We could not load the shared Public page."}
    end
  end

  defp agent_guidance?(entry, current_revision, viewing_revision, sources) do
    entry.status == :draft and
      (is_nil(current_revision) or sources == [] or
         stale_revision?(current_revision, viewing_revision))
  end

  defp stale_revision?(_current_revision, nil), do: false

  defp stale_revision?(current_revision, viewing_revision),
    do: current_revision.id != viewing_revision.id

  defp agent_guidance(entry, nil, _viewing_revision, _sources) do
    %{
      title: "Draft needs an agent revision",
      description: "There is no rendered document to review yet.",
      task:
        "Create the customer-visible Changelog release for #{entry.title}. Write the Markdown document, attach source evidence, and publish it through the agent."
    }
  end

  defp agent_guidance(entry, current_revision, _viewing_revision, [])
       when not is_nil(current_revision) do
    %{
      title: "Draft needs release evidence",
      description: "The document is ready for analysis, but release evidence is missing.",
      task:
        "Attach at least one customer-visible source reference to the #{entry.title} release, then publish it through the agent."
    }
  end

  defp agent_guidance(entry, %{id: current_id}, %{id: viewing_id}, _sources)
       when current_id != viewing_id do
    %{
      title: "Review the latest agent revision",
      description: "This deep link shows an older revision and cannot be released.",
      task:
        "Review the latest #{entry.title} revision, attach current source evidence if needed, and publish the current revision through the agent."
    }
  end

  defp activity_tone("success"), do: "success"
  defp activity_tone(outcome) when outcome in ["denied", "failed"], do: "error"
  defp activity_tone(_outcome), do: "neutral"

  defp publication_state(public_page, %{status: :published, public_slug: entry_slug})
       when is_binary(entry_slug) do
    if public_page && public_page.published_at do
      %{
        label: "Published",
        tone: "success",
        message: "Customers can view this entry at its frozen public address.",
        url:
          AlplusWeb.Endpoint.url() <>
            "/status/#{public_page.public_slug}/changelog/#{entry_slug}"
      }
    else
      %{
        label: "Public page unpublished",
        tone: "warning",
        message: "Publish the shared Public page before customers can view this entry.",
        url: nil
      }
    end
  end

  defp publication_state(public_page, %{status: :published}) do
    %{
      label: "Published",
      tone: "warning",
      message:
        if(public_page && public_page.published_at,
          do: "This published entry has no public address yet.",
          else: "Publish the shared Public page before customers can view this entry."
        ),
      url: nil
    }
  end

  defp publication_state(_public_page, %{status: :archived}) do
    %{
      label: "Archived",
      tone: "neutral",
      message: "This entry is hidden from the public Changelog until it is restored.",
      url: nil
    }
  end

  defp publication_state(public_page, %{status: :draft}) do
    message =
      if public_page && public_page.published_at,
        do: "This entry stays private until you publish it.",
        else: "The Public page is unpublished, so customers cannot view entries yet."

    %{
      label: "Draft",
      tone: "neutral",
      message: message,
      url: nil
    }
  end
end
