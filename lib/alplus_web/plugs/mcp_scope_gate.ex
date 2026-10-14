defmodule AlplusWeb.Plugs.McpScopeGate do
  @moduledoc "Caches the MCP JSON body for ExMCP and recognizes only gateway tools at the wire boundary. Gateway resolves action scopes."

  @behaviour Plug

  import Plug.Conn

  @gateway_tools ~w(context.get actions.search actions.get actions.read actions.write actions.publish actions.destroy confirmations.get)

  @body_limit 1_000_000

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST"} = conn, _opts) do
    case take_body(conn) do
      {:ok, body, conn} ->
        conn
        |> assign(:raw_body, body)
        |> maybe_forbid(body)

      :unreadable ->
        conn
    end
  end

  def call(conn, _opts), do: conn

  defp take_body(%{assigns: %{raw_body: body}} = conn) when is_binary(body),
    do: {:ok, body, conn}

  defp take_body(conn) do
    case Plug.Conn.read_body(conn, length: @body_limit, read_length: @body_limit) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, body, conn} -> {:ok, body <> <<0>>, conn}
      {:error, _reason} -> :unreadable
    end
  end

  defp maybe_forbid(conn, body) do
    case tools_call(body) do
      {:ok, _tool} -> conn
      :pass -> conn
    end
  end

  defp tools_call(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"method" => "tools/call", "params" => %{"name" => name}}}
      when name in @gateway_tools ->
        {:ok, name}

      _ ->
        :pass
    end
  end
end
