defmodule Alplus.Notifications.Message do
  @moduledoc """
  Turns one notification event into the content every channel sends.

  An event names a trigger and a subject id. This module reads the subject and
  writes what a person needs to act: what happened, where, and a link to it.
  Email renders the whole message. Chat and webhook channels send `text/1`.

  The subject is read with the organization id from the job, so an event can
  never describe a row that belongs to another organization. A subject that
  no longer exists yields the generic message.
  """

  require Ash.Query

  alias Alplus.Monitoring.{Incident, Monitor}
  alias Alplus.Observe.Issue
  alias Alplus.Orgs.Organization
  alias Alplus.Projects.Project

  @type t :: %{
          subject: String.t(),
          heading: String.t(),
          summary: String.t(),
          detail: String.t() | nil,
          facts: [{String.t(), String.t()}],
          action: {String.t(), String.t()} | nil
        }

  @issue_triggers %{
    "new_issue" => {"New error", "New error in"},
    "issue_regression" => {"Error is back", "A resolved error is back in"},
    "error_spike" => {"Error spike", "Error spike in"}
  }

  @spec build(map()) :: t()
  def build(%{"subject_type" => "issue", "trigger" => trigger} = event)
      when is_map_key(@issue_triggers, trigger) do
    with {:ok, issue} <- fetch(Issue, event),
         {:ok, org, project} <- place(issue) do
      {label, heading} = Map.fetch!(@issue_triggers, trigger)

      %{
        subject: "[#{project.name}] #{label}: #{clip(issue.title, 120)}",
        heading: "#{heading} #{project.name}",
        summary: clip(issue.title, 400),
        detail: issue.culprit,
        facts:
          facts([
            {"Environment", issue.environment},
            {"Level", issue.level},
            {"Events", Integer.to_string(issue.event_count)},
            {"First seen", time(issue.first_seen_at)},
            {"Last seen", time(issue.last_seen_at)},
            {"Release", release(issue.release_last_seen)}
          ]),
        action: {"Open the issue", project_url(org, project, "/observe/issues/#{issue.id}")}
      }
    else
      _ -> generic(event)
    end
  end

  def build(%{"subject_type" => "project", "trigger" => "quota"} = event) do
    with {:ok, project} <- fetch(Project, event),
         {:ok, org} <- Ash.get(Organization, project.org_id, authorize?: false) do
      %{
        subject: "[#{project.name}] Error event quota reached",
        heading: "#{project.name} reached its error event quota",
        summary:
          "PostDeploy does not store new error events for this organization until the quota resets or the plan changes.",
        detail: nil,
        facts: [],
        action: {"Open billing", url("/dashboard/orgs/#{org.public_token}/billing")}
      }
    else
      _ -> generic(event)
    end
  end

  def build(%{"subject_type" => "incident", "trigger" => trigger} = event)
      when trigger in ["check_down", "check_recovered"] do
    with {:ok, incident} <- fetch(Incident, event),
         {:ok, monitor} <- Ash.get(Monitor, incident.monitor_id, authorize?: false),
         {:ok, org, project} <- place(incident) do
      incident_message(trigger, incident, monitor, org, project)
    else
      _ -> generic(event)
    end
  end

  def build(event), do: generic(event)

  @doc "The message as plain text, for chat and webhook channels."
  @spec text(t()) :: String.t()
  def text(message) do
    [
      message.heading,
      message.summary,
      message.detail,
      Enum.map(message.facts, fn {label, value} -> "#{label}: #{value}" end),
      message.action && elem(message.action, 1)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp incident_message("check_down", incident, monitor, org, project) do
    %{
      subject: "[#{project.name}] Down: #{monitor.name}",
      heading: "#{monitor.name} is down",
      summary: "A check for this monitor failed and PostDeploy opened an incident.",
      detail: nil,
      facts:
        facts([
          {"Cause", incident.cause},
          {"Environment", incident.environment},
          {"Started", time(incident.started_at)},
          {"Failed checks", Integer.to_string(incident.checks_failed_count)}
        ]),
      action: {"Open the monitor", project_url(org, project, "/monitor/#{monitor.id}")}
    }
  end

  defp incident_message("check_recovered", incident, monitor, org, project) do
    %{
      subject: "[#{project.name}] Recovered: #{monitor.name}",
      heading: "#{monitor.name} recovered",
      summary: "A check for this monitor passed and PostDeploy resolved the incident.",
      detail: nil,
      facts:
        facts([
          {"Environment", incident.environment},
          {"Started", time(incident.started_at)},
          {"Resolved", time(incident.resolved_at)},
          {"Duration", duration(incident.duration_seconds)}
        ]),
      action: {"Open the monitor", project_url(org, project, "/monitor/#{monitor.id}")}
    }
  end

  defp generic(%{"trigger" => trigger, "subject_type" => type, "subject_id" => id}) do
    %{
      subject: "PostDeploy #{trigger}: #{type} #{id}",
      heading: "PostDeploy #{trigger}",
      summary: "PostDeploy notification: #{trigger} for #{type} #{id}.",
      detail: nil,
      facts: [],
      action: nil
    }
  end

  defp fetch(resource, %{"subject_id" => id, "org_id" => org_id}) when is_binary(org_id) do
    resource
    |> Ash.Query.filter(id == ^id and org_id == ^org_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{} = record} -> {:ok, record}
      _ -> :error
    end
  end

  defp fetch(_resource, _event), do: :error

  defp place(%{org_id: org_id, project_id: project_id}) do
    with {:ok, org} <- Ash.get(Organization, org_id, authorize?: false),
         {:ok, project} <- Ash.get(Project, project_id, authorize?: false) do
      {:ok, org, project}
    end
  end

  defp project_url(org, project, path),
    do: url("/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}" <> path)

  defp url(path), do: AlplusWeb.Endpoint.url() <> path

  defp facts(pairs), do: Enum.reject(pairs, fn {_label, value} -> value in [nil, ""] end)

  defp time(nil), do: nil
  defp time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  defp release(nil), do: nil
  defp release(release), do: String.slice(release, 0, 12)

  defp duration(nil), do: nil
  defp duration(seconds) when seconds < 60, do: "#{seconds} s"
  defp duration(seconds) when seconds < 3_600, do: "#{div(seconds, 60)} min"
  defp duration(seconds), do: "#{div(seconds, 3_600)} h #{div(rem(seconds, 3_600), 60)} min"

  defp clip(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end
end
