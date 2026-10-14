defmodule Alplus.Notifications.Adapters do
  @moduledoc false

  alias Alplus.Notifications.Message

  @outbound_timeout 10_000

  @spec deliver(String.t(), map(), map()) :: :ok | {:error, :retryable | :permanent}
  def deliver("email", config, event) do
    with {:ok, recipient} <- string_value(config, "to"),
         {:ok, from} <- optional_string_value(config, "from", "alerts@postdeploy.dev") do
      message = Message.build(event)

      email =
        Alplus.Mail.build(
          to: recipient,
          from: {"PostDeploy Alerts", from},
          subject: message.subject,
          heading: message.heading,
          paragraphs: [message.summary],
          detail: message.detail,
          facts: message.facts,
          action: message.action,
          footer_note:
            "You received this because a PostDeploy notification channel sends alerts to this address."
        )

      case Alplus.Mailer.deliver(email) do
        {:ok, _metadata} -> :ok
        {:error, _reason} -> {:error, :retryable}
      end
    end
  end

  def deliver(type, config, event) when type in ["slack", "discord"] do
    with {:ok, url} <- string_value(config, "webhook_url"),
         {:ok, response} <-
           post(url, json: webhook_payload(type, event)) do
      response_result(response.status)
    else
      {:error, :missing_config} -> {:error, :permanent}
      {:error, _reason} -> {:error, :retryable}
    end
  end

  def deliver("webhook", config, event) do
    with {:ok, url} <- string_value(config, "url"),
         {:ok, secret} <- string_value(config, "secret"),
         {:ok, payload} <- Jason.encode(webhook_payload("webhook", event)),
         signature <- signature(secret, payload),
         {:ok, response} <-
           post(url,
             body: payload,
             headers: [
               {"content-type", "application/json"},
               {"x-postdeploy-signature", "sha256=" <> signature}
             ]
           ) do
      response_result(response.status)
    else
      {:error, :missing_config} -> {:error, :permanent}
      {:error, _reason} -> {:error, :retryable}
    end
  end

  def deliver("telegram", config, event) do
    with {:ok, token} <- string_value(config, "bot_token"),
         {:ok, chat_id} <- string_value(config, "chat_id"),
         {:ok, response} <-
           post("https://api.telegram.org/bot" <> token <> "/sendMessage",
             json: %{"chat_id" => chat_id, "text" => body(event)}
           ) do
      response_result(response.status)
    else
      {:error, :missing_config} -> {:error, :permanent}
      {:error, _reason} -> {:error, :retryable}
    end
  end

  def deliver(_type, _config, _event), do: {:error, :permanent}

  @spec webhook_payload(String.t(), map()) :: map()
  def webhook_payload("slack", event), do: %{"text" => body(event)}
  def webhook_payload("discord", event), do: %{"content" => body(event)}

  def webhook_payload("webhook", event) do
    %{
      "event" => "notification",
      "trigger" => event["trigger"],
      "subject_type" => event["subject_type"],
      "subject_id" => event["subject_id"],
      "message" => body(event)
    }
  end

  @spec body(map()) :: String.t()
  def body(event), do: event |> Message.build() |> Message.text()

  defp response_result(status) when status in 200..299, do: :ok
  defp response_result(status) when status in 400..499, do: {:error, :permanent}
  defp response_result(_status), do: {:error, :retryable}

  defp post(url, options) do
    request()
    |> Req.post(Keyword.put(options, :url, url))
  end

  defp request do
    Req.new(
      receive_timeout: @outbound_timeout,
      connect_options: [timeout: @outbound_timeout],
      retry: false
    )
    |> maybe_plug()
  end

  defp maybe_plug(req) do
    case Application.get_env(:alplus, :notifications_req_plug) do
      nil -> req
      plug -> Req.merge(req, plug: plug)
    end
  end

  defp signature(secret, payload) do
    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.encode16(case: :lower)
  end

  defp string_value(config, key) when is_map(config) do
    case Map.get(config, key) || Map.get(config, key_atom(key)) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, :missing_config}
    end
  end

  defp optional_string_value(config, key, default) when is_map(config) do
    case Map.get(config, key) || Map.get(config, key_atom(key)) || default do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, :missing_config}
    end
  end

  defp key_atom("to"), do: :to
  defp key_atom("from"), do: :from
  defp key_atom("webhook_url"), do: :webhook_url
  defp key_atom("url"), do: :url
  defp key_atom("secret"), do: :secret
  defp key_atom("bot_token"), do: :bot_token
  defp key_atom("chat_id"), do: :chat_id
end
