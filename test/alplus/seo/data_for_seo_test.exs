defmodule Alplus.Seo.DataForSeoTest do
  use ExUnit.Case, async: false

  alias Alplus.Seo.DataForSeo

  setup do
    original = Application.get_env(:alplus, :dataforseo_credentials)
    Application.put_env(:alplus, :dataforseo_credentials, %{login: "login", password: "password"})

    on_exit(fn ->
      Application.put_env(:alplus, :dataforseo_credentials, original)
    end)
  end

  test "posts JSON with server-side basic authentication" do
    Req.Test.stub(DataForSeo, fn conn ->
      assert conn.request_path == "/v3/dataforseo_labs/google/ranked_keywords/live"
      assert ["Basic bG9naW46cGFzc3dvcmQ="] = Plug.Conn.get_req_header(conn, "authorization")

      Req.Test.json(conn, %{"tasks" => [%{"status_code" => 20_000}]})
    end)

    assert {:ok, %{"tasks" => [%{"status_code" => 20_000}]}} =
             DataForSeo.post("dataforseo_labs/google/ranked_keywords/live", [
               %{"target" => "example.com"}
             ])
  end

  test "does not send a request without credentials" do
    Application.put_env(:alplus, :dataforseo_credentials, %{})

    assert {:error, :missing_credentials} = DataForSeo.post("any", [])
  end
end
