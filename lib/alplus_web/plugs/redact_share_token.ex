defmodule AlplusWeb.Plugs.RedactShareToken do
  @moduledoc "Redacts a public dashboard bearer before request capture and completion logs."

  def init(opts), do: opts

  def call(%{path_info: ["share", token]} = conn, _opts) when is_binary(token) do
    redact(conn, token)
  end

  def call(%{path_params: %{"token" => token}} = conn, _opts) when is_binary(token) do
    redact(conn, token)
  end

  def call(conn, _opts), do: conn

  defp redact(conn, token) do
    redacted_path = String.replace(conn.request_path, token, "[FILTERED]")

    %{conn | request_path: redacted_path}
  end
end
