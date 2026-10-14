defmodule Alplus.Billing.StripeConfig do
  @moduledoc "Runtime configuration shared by Stripe HTTP boundaries and jobs."

  @environments %{
    "local" => false,
    "preview" => false,
    "staging" => false,
    "production" => true
  }

  @type environment :: String.t()

  @spec webhook_secret() :: {:ok, String.t()} | {:error, :missing_webhook_secret}
  def webhook_secret do
    case Application.get_env(:alplus, :stripe_webhook_secret) do
      secret when is_binary(secret) and byte_size(secret) > 0 -> {:ok, secret}
      _ -> {:error, :missing_webhook_secret}
    end
  end

  @spec environment() :: {:ok, environment()} | {:error, :invalid_stripe_environment}
  def environment do
    case Application.get_env(:alplus, :stripe_environment) do
      environment when is_map_key(@environments, environment) -> {:ok, environment}
      _ -> {:error, :invalid_stripe_environment}
    end
  end

  @spec livemode_matches?(boolean(), environment()) :: boolean()
  def livemode_matches?(livemode, environment)
      when is_boolean(livemode) and is_map_key(@environments, environment) do
    Map.fetch!(@environments, environment) == livemode
  end
end
