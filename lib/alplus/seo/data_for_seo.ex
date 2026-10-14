defmodule Alplus.Seo.DataForSeo do
  @moduledoc "Small server-only client for DataForSEO's v3 API."

  @base_url "https://api.dataforseo.com/v3"
  @timeout_ms 15_000

  @type provider_error :: :missing_credentials | {:http_status, pos_integer()} | term()

  @spec post(String.t(), [map()]) :: {:ok, map()} | {:error, provider_error()}
  def post(path, tasks) when is_binary(path) and is_list(tasks) do
    with {:ok, credentials} <- credentials(),
         {:ok, response} <-
           request(credentials)
           |> Req.post(url: endpoint(path), json: tasks) do
      response_result(response)
    end
  end

  defp response_result(%Req.Response{status: status, body: body}) when status in 200..299,
    do: {:ok, body}

  defp response_result(%Req.Response{status: status}), do: {:error, {:http_status, status}}

  defp credentials do
    case Application.get_env(:alplus, :dataforseo_credentials, %{}) do
      %{login: login, password: password}
      when is_binary(login) and byte_size(login) > 0 and is_binary(password) and
             byte_size(password) > 0 ->
        {:ok, {login, password}}

      _ ->
        {:error, :missing_credentials}
    end
  end

  defp request({login, password}) do
    Req.new(
      headers: [{"authorization", "Basic " <> Base.encode64(login <> ":" <> password)}],
      receive_timeout: @timeout_ms,
      connect_options: [timeout: @timeout_ms],
      retry: false
    )
    |> maybe_plug()
  end

  defp endpoint(path), do: @base_url <> "/" <> String.trim_leading(path, "/")

  defp maybe_plug(req) do
    case Application.get_env(:alplus, :dataforseo_req_plug) do
      nil -> req
      plug -> Req.merge(req, plug: plug)
    end
  end
end
