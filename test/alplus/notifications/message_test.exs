defmodule Alplus.Notifications.MessageTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures
  import Swoosh.TestAssertions

  alias Alplus.Notifications.{Adapters, Message}
  alias Alplus.Observe.Ingest

  setup do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org, %{name: "Storm Portal"})
    {source, _secret} = source_fixture(owner_scope, org, project)

    {:ok, %{event_ids: [event_id]}} =
      Ingest.capture_item(source, %{
        "event_id" => "0198f0a1-7c01-7000-8000-0000000000a1" |> String.replace("-", ""),
        "type" => "exception",
        "timestamp" => "2026-10-01T23:01:19Z",
        "level" => "error",
        "release" => "a235662b8fac3cb8c86109742302515c31312fbd",
        "exception" => %{
          "type" => "Airtable::Client::RequestError",
          "value" => "upsert_record failed (503)",
          "stacktrace" => %{
            "frames" => [
              %{
                "file" => "app/services/airtable/client.rb",
                "function" => "upsert_record",
                "in_app" => true
              }
            ]
          }
        }
      })

    [[issue_id]] =
      Alplus.Repo.query!("SELECT issue_id FROM error_events WHERE event_id = $1", [event_id]).rows

    event = %{
      "org_id" => org.id,
      "trigger" => "new_issue",
      "subject_type" => "issue",
      "subject_id" => issue_id
    }

    %{org: org, project: project, issue_id: issue_id, event: event}
  end

  test "a new issue alert names the project, the error, its location, and links to it", %{
    org: org,
    project: project,
    issue_id: issue_id,
    event: event
  } do
    message = Message.build(event)

    assert message.subject ==
             "[Storm Portal] New error: Airtable::Client::RequestError: upsert_record failed (503)"

    assert message.heading == "New error in Storm Portal"
    assert message.summary == "Airtable::Client::RequestError: upsert_record failed (503)"
    assert message.detail == "app/services/airtable/client.rb:upsert_record"

    assert {"Environment", "production"} in message.facts
    assert {"Events", "1"} in message.facts
    assert {"Release", "a235662b8fac"} in message.facts

    assert message.action ==
             {"Open the issue",
              AlplusWeb.Endpoint.url() <>
                "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe/issues/#{issue_id}"}
  end

  test "a regression alert says the error is back", %{event: event} do
    message = Message.build(%{event | "trigger" => "issue_regression"})

    assert message.heading == "A resolved error is back in Storm Portal"
    assert String.starts_with?(message.subject, "[Storm Portal] Error is back: ")
  end

  test "an event from another organization never reads the issue", %{event: event} do
    {other_org, _scope} = org_fixture(scope_fixture())
    message = Message.build(%{event | "org_id" => other_org.id})

    assert message.subject == "PostDeploy new_issue: issue #{event["subject_id"]}"
    assert message.action == nil
  end

  test "the email channel sends the alert with both parts", %{event: event, issue_id: issue_id} do
    assert :ok = Adapters.deliver("email", %{"to" => "oncall@example.com"}, event)

    assert_email_sent(fn email ->
      assert email.from == {"PostDeploy Alerts", "alerts@postdeploy.dev"}

      assert email.subject ==
               "[Storm Portal] New error: Airtable::Client::RequestError: upsert_record failed (503)"

      for part <- [email.html_body, email.text_body] do
        assert part =~ "New error in Storm Portal"
        assert part =~ "app/services/airtable/client.rb:upsert_record"
        assert part =~ "production"
        assert part =~ "/observe/issues/#{issue_id}"
      end
    end)
  end

  test "chat channels send the same facts as text", %{event: event, issue_id: issue_id} do
    text = Adapters.body(event)

    assert text =~ "New error in Storm Portal\nAirtable::Client::RequestError"
    assert text =~ "Environment: production"
    assert String.ends_with?(text, "/observe/issues/#{issue_id}")
  end
end
