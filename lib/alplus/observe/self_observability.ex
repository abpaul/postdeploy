defmodule Alplus.Observe.SelfObservability do
  @moduledoc false

  # A LiveView socket whose Origin is not the configured host is rejected by
  # `check_origin`, which is the control working. It is logged at error level by
  # Phoenix, so it reached our own Observe project as an issue and competed with
  # real faults. `ingest.postdeploy.dev` is the common source: a browser that
  # reaches the ingest host keeps that origin for the socket, and the host
  # redirect only covers document requests, never the websocket upgrade.
  @origin_check_message "Could not check origin for Phoenix.Socket transport."

  @doc false
  @spec before_send(Sentry.Event.t()) :: Sentry.Event.t() | nil
  def before_send(%Sentry.Event{} = event) do
    if read_timeout?(event) or origin_check?(event), do: nil, else: event
  end

  defp read_timeout?(%Sentry.Event{exception: exceptions}) do
    Enum.any?(exceptions, &match?(%{type: "Bandit.HTTPError", value: "Read timeout"}, &1))
  end

  defp origin_check?(%Sentry.Event{message: %{formatted: message}}) when is_binary(message),
    do: String.starts_with?(message, @origin_check_message)

  defp origin_check?(_event), do: false
end
