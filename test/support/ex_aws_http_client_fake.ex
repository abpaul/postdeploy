defmodule Alplus.ExAwsHTTPClientFake do
  @moduledoc false

  @behaviour ExAws.Request.HttpClient

  @impl true
  def request(method, url, body, headers, _http_opts) do
    send(
      Application.fetch_env!(:ex_aws, :test_pid),
      {:ex_aws_request, method, url, body, headers}
    )

    {:ok, %{status_code: 200, headers: [], body: ""}}
  end
end
