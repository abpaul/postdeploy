defmodule Alplus.MailerTest do
  use ExUnit.Case, async: false

  alias Alplus.Mailer

  setup do
    original = Application.fetch_env(:alplus, :mail_from)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:alplus, :mail_from, value)
        :error -> Application.delete_env(:alplus, :mail_from)
      end
    end)

    :ok
  end

  describe "from_address/0" do
    test "returns a configured {name, address} tuple unchanged" do
      Application.put_env(:alplus, :mail_from, {"Support", "support@alp.app"})
      assert Mailer.from_address() == {"Support", "support@alp.app"}
    end

    test "wraps a bare configured address with the default display name" do
      Application.put_env(:alplus, :mail_from, "noreply@alp.app")
      assert Mailer.from_address() == {"PostDeploy", "noreply@alp.app"}
    end

    test "falls back to a placeholder when unset (dev/test)" do
      Application.delete_env(:alplus, :mail_from)
      assert Mailer.from_address() == {"PostDeploy", "noreply@example.com"}
    end
  end
end
