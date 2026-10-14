defmodule AlplusWeb.WebMcpController do
  @moduledoc "Authenticated same-origin entry point for the shared MCP dispatch seam."

  use AlplusWeb, :controller

  alias Alplus.Mcp.{Error, Gateway, Principal}

  @doc "Executes one gateway operation for the current dashboard session."
  def execute(conn, %{"tool" => tool, "arguments" => arguments} = params)
      when is_binary(tool) and is_map(arguments) do
    with {:ok, scope} <- session_scope(conn, params),
         principal <- Principal.from_session(scope),
         :ok <- cancellation(conn),
         {:ok, result} <- Gateway.call(tool, arguments, principal) do
      json(conn, %{ok: true, result: result, untrusted: true})
    else
      {:error, %Error{} = error} -> error_response(conn, error)
      {:error, _reason} -> error_response(conn, Error.from(:not_found))
    end
  end

  def execute(conn, _params), do: error_response(conn, Error.from(:invalid_argument))

  @doc "Returns the gateway tools for the current dashboard session."
  def catalog(conn, %{"org_id" => org_id, "project_handle" => project_handle}) do
    with {:ok, scope} <-
           session_scope(conn, %{"org_id" => org_id, "project_handle" => project_handle}) do
      tools =
        scope
        |> Principal.from_session()
        |> Gateway.wire_tools()

      json(conn, %{tools: tools})
    else
      _ -> json(conn |> put_status(404), %{error: %{code: "not_found"}})
    end
  end

  def catalog(conn, _params), do: json(conn |> put_status(404), %{error: %{code: "not_found"}})

  defp session_scope(%{assigns: %{current_user: %{id: user_id}}}, %{
         "org_id" => org_id,
         "project_handle" => project_handle
       })
       when is_binary(org_id) and is_binary(project_handle) do
    base = Alplus.Scope.for_user(user_id)

    with {:ok, org_scope} <- Alplus.Orgs.build_scope(base, org_id),
         {:ok, project} <- Alplus.Projects.get_project(project_handle, actor: org_scope),
         true <- project.org_id == org_scope.org_id do
      {:ok, Alplus.Scope.put_project(org_scope, project.id)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp session_scope(_conn, _params), do: {:error, :not_found}

  defp cancellation(conn) do
    case Plug.Conn.get_req_header(conn, "x-webmcp-cancel") do
      ["true"] -> {:error, Error.from(:cancelled)}
      _ -> :ok
    end
  end

  defp error_response(conn, %Error{} = error) do
    conn
    |> put_status(200)
    |> json(%{ok: false, error: %{code: Atom.to_string(error.code), message: error.message}})
  end
end
