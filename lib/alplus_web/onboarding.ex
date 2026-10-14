defmodule AlplusWeb.Onboarding do
  @moduledoc """
  Derives activation from authoritative rows.

  Activation is deliberately separate from the older product checklist below:
  the runway must be resumable after a refresh or sign-out and therefore uses
  only the confirmed user, selected organization/project, and a real allowed
  agent AuditLog row for that project. Credential existence never completes
  connection. No progress flag is persisted.
  """

  require Ash.Query

  @type activation_step :: %{
          key: atom(),
          title: String.t(),
          description: String.t(),
          done?: boolean(),
          state: :done | :current | :todo
        }

  @doc """
  Builds the ordered activation runway from already scoped facts.

  The input map is intentionally data-shaped so callers can load each
  collection once and keep mount free of N+1 queries. `:user_confirmed?`,
  `:organization`, `:project`, and an allowed agent `:audit` or explicit
  `:connection` are the only completion facts. `:credential` is ignored.
  Audit metadata is never rendered here.
  """
  @spec activation(map()) :: [activation_step()]
  def activation(facts) when is_map(facts) do
    connection_done? = present?(facts, :connection) or present?(facts, :audit)
    analysis_done? = present?(facts, :analysis)

    [
      step(
        :email_verification,
        "Verify your email",
        "Confirm your email before activating a workspace.",
        Map.get(facts, :user_confirmed?, Map.get(facts, "user_confirmed?", false))
      ),
      step(
        :organization,
        "Choose an organization",
        "Create or select the workspace for this project.",
        present?(facts, :organization)
      ),
      step(
        :project,
        "Choose a project",
        "Create or select the project the agent can access.",
        present?(facts, :project)
      ),
      step(
        :connection,
        "Connect an agent",
        "Add the MCP URL. The client opens a browser so you can sign in, select a project, and approve access.",
        connection_done?
      ),
      step(
        :analysis,
        "Open project analysis",
        "Review current health, changes, and investigations.",
        analysis_done?
      )
    ]
    |> mark_states()
  end

  @doc "Returns the first incomplete activation key, or nil when complete."
  @spec first_incomplete([activation_step()]) :: atom() | nil
  def first_incomplete(steps), do: Enum.find_value(steps, &if(&1.done?, do: nil, else: &1.key))

  defp step(key, title, description, done?) do
    %{key: key, title: title, description: description, done?: done?}
  end

  defp present?(facts, key),
    do: Map.get(facts, key, Map.get(facts, to_string(key))) not in [nil, false]

  # Existing project checklist API. Kept stable for the project list while the
  # activation runway is introduced.

  alias Alplus.Measure.AnalyticsDay
  alias Alplus.Monitoring.{Monitor, MonitorCheck}
  alias Alplus.Observe.Issue
  alias Alplus.Projects.{Project, ProjectDomain}
  alias Alplus.Sources.Source

  @type step :: %{
          key: atom(),
          title: String.t(),
          description: String.t(),
          done?: boolean(),
          state: :done | :current | :todo
        }

  @doc """
  Returns the four checklist steps for the org in `scope`, with a derived
  `:state`. Assumes `scope.org_id` is set (the org already exists).
  """
  @spec checklist(Alplus.Scope.t()) :: [step()]
  def checklist(%Alplus.Scope{org_id: org_id} = scope) when is_binary(org_id) do
    project_ids = project_ids_for_org(org_id, scope)

    steps =
      [
        %{
          key: :organization,
          title: "Create your organization",
          description: "Your team's workspace. One login, one bill.",
          done?: true
        },
        %{
          key: :project,
          title: "Create your first project",
          description: "A project groups the monitors, errors, and analytics for one app.",
          done?: project_ids != []
        },
        %{
          key: :integrate,
          title: "Add your first tool",
          description:
            "Monitor is the fastest way to see PostDeploy working. No code, no deploy. " <>
              "Measure and Observe are one snippet away when you're ready.",
          done?:
            any_in_org_projects?(Monitor, org_id, project_ids, scope) or
              any_in_org_projects?(Source, org_id, project_ids, scope) or
              any_in_org_projects?(ProjectDomain, org_id, project_ids, scope)
        },
        %{
          key: :first_value,
          title: "See it work",
          description: "A check result, an error, or a pageview lands here, usually in minutes.",
          done?:
            any_in_org_projects?(MonitorCheck, org_id, project_ids, scope) or
              any_in_org_projects?(Issue, org_id, project_ids, scope) or
              any_in_org_projects?(AnalyticsDay, org_id, project_ids, scope)
        }
      ]

    mark_states(steps)
  end

  @doc "True when every checklist step is done."
  @spec complete?([step()]) :: boolean()
  def complete?(steps), do: Enum.all?(steps, & &1.done?)

  @doc "The count of completed steps, for a progress label."
  @spec done_count([step()]) :: non_neg_integer()
  def done_count(steps), do: Enum.count(steps, & &1.done?)

  @doc """
  Marks the ordered checklist path without changing the persisted-row truth.

  The first not-done step is `:current`; earlier ones are `:done`; later ones
  are `:todo`. Once a step is blocked, a later row must not make that later
  step look current or done: the ordered path is the contract users follow.
  """
  @spec mark_states([
          %{
            required(:key) => atom(),
            required(:title) => String.t(),
            required(:description) => String.t(),
            required(:done?) => boolean(),
            optional(:state) => :done | :current | :todo
          }
        ]) :: [step()]
  def mark_states(steps) do
    {marked, _current_taken} =
      Enum.map_reduce(steps, false, fn step, current_taken ->
        cond do
          current_taken -> {Map.put(step, :state, :todo), true}
          step.done? -> {Map.put(step, :state, :done), false}
          true -> {Map.put(step, :state, :current), true}
        end
      end)

    marked
  end

  # One existence action per checklist fact. Each action applies the
  # organization and explicit project set in SQL, so this stays constant-cost
  # as the organization grows.
  defp any_in_org_projects?(_resource, _org_id, [], _scope), do: false

  defp any_in_org_projects?(resource, org_id, project_ids, scope) do
    resource
    |> Ash.Query.for_read(
      :exists_for_projects,
      %{project_ids: project_ids},
      actor: scope
    )
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: scope)
    |> Enum.any?()
  end

  defp project_ids_for_org(org_id, scope) do
    Project
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.select([:id])
    |> Ash.read!(actor: scope)
    |> Enum.map(& &1.id)
  end
end
