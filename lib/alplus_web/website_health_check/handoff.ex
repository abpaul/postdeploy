defmodule AlplusWeb.WebsiteHealthCheck.Handoff do
  @moduledoc false

  import Plug.Conn

  @continue_path "/tools/website-health-check/continue"
  @draft_key "health_check_draft"
  @journey_key "health_check_journey_id"
  @ttl_seconds 24 * 60 * 60

  @spec continue_path() :: String.t()
  def continue_path, do: @continue_path

  @spec continue_path(map()) :: String.t() | nil
  def continue_path(session) when is_map(session) do
    path = session["return_to"] || session[:return_to]
    if path == @continue_path, do: @continue_path
  end

  @spec journey_id(Plug.Conn.t()) :: {Plug.Conn.t(), String.t()}
  def journey_id(conn) do
    case get_session(conn, @journey_key) do
      id when is_binary(id) and byte_size(id) > 0 ->
        {conn, id}

      _ ->
        id = Alplus.Growth.HealthCheck.new_journey_id()
        {put_session(conn, @journey_key, id), id}
    end
  end

  @doc """
  Carries the journey id a LiveView generated into the session, so the five
  funnel stages stay one journey across the handoff. Anything that is not a
  journey id is ignored rather than stored.
  """
  @spec put_journey_id(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def put_journey_id(conn, id) when is_binary(id) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]{22}\z/, id) do
      put_session(conn, @journey_key, id)
    else
      conn
    end
  end

  def put_journey_id(conn, _id), do: conn

  @spec put_draft(Plug.Conn.t(), String.t(), String.t() | nil) :: Plug.Conn.t()
  def put_draft(conn, url, keyword) do
    put_session(conn, @draft_key, %{
      "url" => url,
      "keyword" => keyword,
      "created_at" => DateTime.to_iso8601(DateTime.utc_now())
    })
  end

  @spec peek(Plug.Conn.t()) :: {:ok, map()} | :missing | :expired
  def peek(conn) do
    case get_session(conn, @draft_key) do
      %{"url" => url, "created_at" => created_at} = draft when is_binary(url) ->
        with {:ok, at, _} <- DateTime.from_iso8601(created_at),
             true <- DateTime.diff(DateTime.utc_now(), at, :second) <= @ttl_seconds do
          {:ok, %{url: url, keyword: blank_to_nil(draft["keyword"])}}
        else
          _ -> :expired
        end

      _ ->
        :missing
    end
  end

  @spec delete(Plug.Conn.t()) :: Plug.Conn.t()
  def delete(conn), do: delete_session(conn, @draft_key)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
