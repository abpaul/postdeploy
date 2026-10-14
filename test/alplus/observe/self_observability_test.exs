defmodule Alplus.Observe.SelfObservabilityTest do
  use ExUnit.Case, async: true

  alias Alplus.Observe.SelfObservability

  test "drops Bandit connection read timeout events" do
    event =
      Sentry.Event.transform_exception(
        %Bandit.HTTPError{message: "Read timeout", plug_status: 408},
        []
      )

    assert SelfObservability.before_send(event) == nil
  end

  test "drops a rejected socket origin, which is the origin check working" do
    event =
      Sentry.Event.create_event(
        message:
          "Could not check origin for Phoenix.Socket transport.\n\nOrigin of the request: https://ingest.postdeploy.dev\n"
      )

    assert SelfObservability.before_send(event) == nil
  end

  test "keeps all other events" do
    events = [
      Sentry.Event.transform_exception(
        %Bandit.HTTPError{message: "Request timeout", plug_status: 408},
        []
      ),
      Sentry.Event.transform_exception(%RuntimeError{message: "Read timeout"}, []),
      Sentry.Event.create_event(message: "Read timeout"),
      Sentry.Event.create_event(message: "Origin of the request: https://ingest.postdeploy.dev")
    ]

    for event <- events do
      assert SelfObservability.before_send(event) == event
    end
  end
end
