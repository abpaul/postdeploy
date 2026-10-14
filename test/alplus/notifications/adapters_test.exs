defmodule Alplus.Notifications.AdaptersTest do
  use ExUnit.Case, async: false

  alias Alplus.Notifications.Adapters

  setup do
    previous = Application.get_env(:alplus, :notifications_req_plug)
    Application.put_env(:alplus, :notifications_req_plug, {Req.Test, Adapters})

    on_exit(fn ->
      if previous do
        Application.put_env(:alplus, :notifications_req_plug, previous)
      else
        Application.delete_env(:alplus, :notifications_req_plug)
      end
    end)

    :ok
  end

  defp event do
    %{
      "trigger" => "quota",
      "subject_type" => "project",
      "subject_id" => "project_test"
    }
  end

  test "delivers a signed webhook without putting the secret in the payload" do
    secret = Base.encode64(:crypto.strong_rand_bytes(32))

    Req.Test.stub(Adapters, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      refute body =~ secret
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      assert [signature] = Plug.Conn.get_req_header(conn, "x-postdeploy-signature")
      assert String.starts_with?(signature, "sha256=")
      Req.Test.json(conn, %{"accepted" => true})
    end)

    assert :ok =
             Adapters.deliver(
               "webhook",
               %{"url" => "https://receiver.example.test/events", "secret" => secret},
               event()
             )
  end

  test "delivers a Telegram message through its bot endpoint" do
    token = "123456789:" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    Req.Test.stub(Adapters, fn conn ->
      assert String.ends_with?(conn.request_path, "/sendMessage")
      Req.Test.json(conn, %{"ok" => true})
    end)

    assert :ok =
             Adapters.deliver(
               "telegram",
               %{"bot_token" => token, "chat_id" => "chat-test"},
               event()
             )
  end

  test "maps webhook client and server failures to terminal and retryable states" do
    Req.Test.stub(Adapters, fn conn -> Plug.Conn.send_resp(conn, 400, "rejected") end)

    assert {:error, :permanent} =
             Adapters.deliver(
               "webhook",
               %{
                 "url" => "https://receiver.example.test/events",
                 "secret" => Base.encode64(:crypto.strong_rand_bytes(32))
               },
               event()
             )

    Req.Test.stub(Adapters, fn conn -> Plug.Conn.send_resp(conn, 503, "temporary") end)

    assert {:error, :retryable} =
             Adapters.deliver(
               "telegram",
               %{
                 "bot_token" =>
                   "123456789:" <>
                     Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
                 "chat_id" => "chat-test"
               },
               event()
             )
  end

  test "maps a transport failure to retryable without returning request details" do
    Req.Test.stub(Adapters, fn conn -> Req.Test.transport_error(conn, :timeout) end)
    secret = Base.encode64(:crypto.strong_rand_bytes(32))

    assert {:error, :retryable} =
             Adapters.deliver(
               "webhook",
               %{"url" => "https://receiver.example.test/events", "secret" => secret},
               event()
             )
  end
end
