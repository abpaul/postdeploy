defmodule Alplus.Measure.OriginAllowlist do
  @moduledoc false

  @max_hostname_bytes 255

  @spec normalize(String.t()) :: {:ok, String.t()} | {:error, :invalid_hostname}
  def normalize(value) when is_binary(value) do
    hostname =
      value
      |> String.trim()
      |> String.downcase()
      |> strip_scheme()
      |> String.split("/", parts: 2)
      |> hd()
      |> String.split(":", parts: 2)
      |> hd()

    if valid_entry?(hostname), do: {:ok, hostname}, else: {:error, :invalid_hostname}
  end

  def normalize(_), do: {:error, :invalid_hostname}

  @spec origin_hostname(String.t() | nil) :: String.t() | nil
  def origin_hostname(origin) when is_binary(origin) and origin not in ["", "null"] do
    case URI.parse(origin) do
      %URI{host: host} when is_binary(host) and host != "" -> String.downcase(host)
      _ -> nil
    end
  end

  def origin_hostname(_), do: nil

  @spec allowed?(String.t(), [String.t()]) :: boolean()
  def allowed?(hostname, domains) when is_binary(hostname) and is_list(domains) do
    Enum.any?(domains, &matches?(hostname, &1))
  end

  defp strip_scheme(value) do
    Regex.replace(~r/^[a-z][a-z0-9+.-]*:\/\//i, value, "")
    |> String.replace_prefix("//", "")
  end

  defp valid_entry?(hostname) do
    hostname != "" and hostname != "*" and byte_size(hostname) <= @max_hostname_bytes and
      not Regex.match?(~r/[\s\/:]/, hostname) and valid_labels?(hostname)
  end

  defp valid_labels?("*." <> suffix) do
    labels = String.split(suffix, ".")
    length(labels) >= 2 and Enum.all?(labels, &valid_label?/1)
  end

  defp valid_labels?(hostname), do: hostname |> String.split(".") |> Enum.all?(&valid_label?/1)
  defp valid_label?(label), do: Regex.match?(~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/, label)

  defp matches?(hostname, "*." <> suffix),
    do: String.ends_with?(hostname, "." <> suffix) and byte_size(hostname) > byte_size(suffix) + 1

  defp matches?(hostname, entry), do: hostname == entry
end
