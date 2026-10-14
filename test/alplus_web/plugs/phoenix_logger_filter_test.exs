defmodule AlplusWeb.Plugs.PhoenixLoggerFilterTest do
  use ExUnit.Case, async: true

  test "filters nested password, token, secret, key, and authorization values" do
    params = %{
      "user" => %{
        "password" => "password-value",
        "password_confirmation" => "confirmation-value",
        "profile" => %{"secret" => "secret-value"}
      },
      "token" => "token-value",
      "credentials" => [
        %{"api_key" => "api-key-value", "authorization" => "Bearer token-value"}
      ],
      "display_name" => "safe-value"
    }

    assert Phoenix.Logger.filter_values(params) == %{
             "user" => %{
               "password" => "[FILTERED]",
               "password_confirmation" => "[FILTERED]",
               "profile" => %{"secret" => "[FILTERED]"}
             },
             "token" => "[FILTERED]",
             "credentials" => [
               %{"api_key" => "[FILTERED]", "authorization" => "[FILTERED]"}
             ],
             "display_name" => "safe-value"
           }
  end
end
