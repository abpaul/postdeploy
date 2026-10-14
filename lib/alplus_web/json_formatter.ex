defmodule AlplusWeb.JSONFormatter do
  @moduledoc "Production Logger formatter for one JSON object per line."

  @metadata_keys ~w(request_id user_id org_id job_id kamal_version)a
  @message_pattern Logger.Formatter.compile("$message")

  @spec format(atom(), term(), term(), keyword()) :: IO.chardata()
  def format(level, message, timestamp, metadata) do
    payload = %{
      "timestamp" => timestamp(timestamp),
      "level" => Atom.to_string(level),
      "message" => message_to_string(message, timestamp),
      "metadata" => metadata_map(metadata)
    }

    [Jason.encode!(payload), "\n"]
  end

  defp message_to_string(message, timestamp) do
    @message_pattern
    |> Logger.Formatter.format(:info, message, timestamp, [])
    |> IO.iodata_to_binary()
  end

  defp metadata_map(metadata) do
    metadata
    |> Keyword.put_new(:kamal_version, System.get_env("KAMAL_VERSION"))
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      if key in @metadata_keys and not is_nil(value) do
        Map.put(acc, Atom.to_string(key), json_value(value))
      else
        acc
      end
    end)
  end

  defp json_value(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp json_value(value) when is_atom(value), do: Atom.to_string(value)
  defp json_value(value), do: inspect(value)

  defp timestamp({{year, month, day}, {hour, minute, second, millisecond}}) do
    naive = NaiveDateTime.new!(year, month, day, hour, minute, second, millisecond * 1_000)
    DateTime.to_iso8601(DateTime.from_naive!(naive, "Etc/UTC"))
  end
end
