defmodule Alplus.Measure.VisitorHash do
  @moduledoc false

  alias Alplus.Measure.VisitorSalt

  @spec hash(String.t(), String.t(), tuple(), String.t() | nil, DateTime.t()) :: String.t()
  def hash(project_id, source_id, remote_ip, user_agent, %DateTime{} = now) do
    day = DateTime.to_date(now)
    daily_salt = VisitorSalt.fetch!(day)
    ip = remote_ip |> :inet.ntoa() |> to_string()
    user_agent = user_agent || ""

    :crypto.mac(:hmac, :sha256, daily_salt, [
      project_id,
      "|",
      source_id,
      "|",
      ip,
      "|",
      user_agent
    ])
    |> Base.encode16(case: :lower)
  end
end
