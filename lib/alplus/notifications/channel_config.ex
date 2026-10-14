defmodule Alplus.Notifications.ChannelConfig do
  @moduledoc """
  Validates notification channel configuration at the Ash action boundary.

  The validator returns one generic error. It never includes a destination,
  token, or secret in an error value.
  """

  @max_url_length 2_048
  @max_email_length 320

  @spec validate(String.t(), map()) :: :ok | {:error, :invalid_config}
  def validate("email", config) when is_map(config) do
    with {:ok, address} <- required(config, "to"),
         true <- byte_size(address) <= @max_email_length,
         true <- Regex.match?(~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/, address) do
      :ok
    else
      _ -> {:error, :invalid_config}
    end
  end

  def validate(type, config) when type in ["slack", "discord"] and is_map(config) do
    with {:ok, url} <- required(config, "webhook_url"),
         :ok <- https_url(url) do
      :ok
    else
      _ -> {:error, :invalid_config}
    end
  end

  def validate("webhook", config) when is_map(config) do
    with {:ok, url} <- required(config, "url"),
         {:ok, secret} <- required(config, "secret"),
         :ok <- https_url(url),
         true <- byte_size(secret) in 16..256 do
      :ok
    else
      _ -> {:error, :invalid_config}
    end
  end

  def validate("telegram", config) when is_map(config) do
    with {:ok, token} <- required(config, "bot_token"),
         {:ok, chat_id} <- required(config, "chat_id"),
         true <- byte_size(token) in 10..256,
         true <- byte_size(chat_id) in 1..64,
         false <- Regex.match?(~r/\s/, token),
         false <- Regex.match?(~r/\s/, chat_id) do
      :ok
    else
      _ -> {:error, :invalid_config}
    end
  end

  def validate(_type, _config), do: {:error, :invalid_config}

  defp required(config, key) do
    case Map.get(config, key) || Map.get(config, atom_key(key)) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, :invalid_config}
    end
  end

  defp atom_key("to"), do: :to
  defp atom_key("webhook_url"), do: :webhook_url
  defp atom_key("url"), do: :url
  defp atom_key("secret"), do: :secret
  defp atom_key("bot_token"), do: :bot_token
  defp atom_key("chat_id"), do: :chat_id

  defp https_url(url) when is_binary(url) do
    parsed = URI.parse(url)

    if byte_size(url) <= @max_url_length and parsed.scheme == "https" and
         is_binary(parsed.host) and parsed.host != "" and is_nil(parsed.userinfo) and
         is_nil(parsed.fragment) do
      :ok
    else
      {:error, :invalid_config}
    end
  end
end
