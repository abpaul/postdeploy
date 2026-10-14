defmodule Alplus.Notifications.ChannelConfigTest do
  use ExUnit.Case, async: true

  alias Alplus.Notifications.ChannelConfig

  test "validates the supported channel matrix" do
    assert :ok = ChannelConfig.validate("email", %{"to" => "ops@example.com"})

    assert :ok =
             ChannelConfig.validate("slack", %{
               "webhook_url" => "https://hooks.example.test/slack"
             })

    assert :ok =
             ChannelConfig.validate("discord", %{
               "webhook_url" => "https://hooks.example.test/discord"
             })

    assert :ok =
             ChannelConfig.validate("webhook", %{
               "url" => "https://example.test/hook",
               "secret" => String.duplicate("x", 16)
             })

    assert :ok =
             ChannelConfig.validate("telegram", %{
               "bot_token" => String.duplicate("x", 10),
               "chat_id" => "123"
             })
  end

  test "rejects malformed destinations and whitespace-sensitive telegram values" do
    assert {:error, :invalid_config} = ChannelConfig.validate("email", %{"to" => "ops"})

    assert {:error, :invalid_config} =
             ChannelConfig.validate("slack", %{"webhook_url" => "http://hooks.example.test"})

    assert {:error, :invalid_config} =
             ChannelConfig.validate("webhook", %{
               "url" => "https://example.test",
               "secret" => "short"
             })

    assert {:error, :invalid_config} =
             ChannelConfig.validate("telegram", %{"bot_token" => " badtoken ", "chat_id" => "123"})

    assert {:error, :invalid_config} =
             ChannelConfig.validate("telegram", %{
               "bot_token" => String.duplicate("x", 10),
               "chat_id" => " 123"
             })
  end
end
