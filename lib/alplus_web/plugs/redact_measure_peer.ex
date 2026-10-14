defmodule AlplusWeb.Plugs.RedactMeasurePeer do
  @moduledoc false

  def init(opts), do: opts

  def call(conn, _opts) do
    Logger.metadata(remote_ip: nil)
    conn
  end
end
