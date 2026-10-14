defmodule Alplus.Changelog.FrontMatter do
  @moduledoc "Parse and validate the YAML metadata at the top of a Changelog document."

  @public_areas ~w(monitor observe measure platform)
  @metadata_keys ~w(title summary area version media media_url media_alt media_caption)

  @type public_metadata :: %{
          title: String.t(),
          body: String.t(),
          summary: String.t() | nil,
          area: String.t() | nil,
          version: String.t() | nil,
          media_url: String.t() | nil,
          media_alt: String.t() | nil,
          media_caption: String.t() | nil
        }

  @spec parse(String.t()) :: {:ok, %{title: String.t(), body: String.t()}} | {:error, atom()}
  def parse(markdown) when is_binary(markdown) do
    with {:ok, metadata} <- parse_public(markdown) do
      {:ok, Map.take(metadata, [:title, :body])}
    end
  end

  def parse(_), do: {:error, :malformed_yaml}

  @doc "Parses the optional public fields used by the published Changelog surfaces."
  @spec parse_public(String.t()) :: {:ok, public_metadata()} | {:error, atom()}
  def parse_public(markdown) when is_binary(markdown) do
    with {:ok, yaml, body} <- split(markdown),
         {:ok, pairs} <- read_yaml(yaml),
         :ok <- validate_keys(pairs),
         {:ok, title} <- title(pairs),
         {:ok, summary} <- optional_text(pairs, "summary", 500, :invalid_summary),
         {:ok, area} <- area(pairs),
         {:ok, version} <- optional_text(pairs, "version", 80, :invalid_version),
         {:ok, media_url} <- media_url(pairs),
         {:ok, media_alt} <- optional_text(pairs, "media_alt", 300, :invalid_media_alt),
         {:ok, media_caption} <-
           optional_text(pairs, "media_caption", 300, :invalid_media_caption),
         :ok <- validate_media(media_url, media_alt),
         :ok <- reject_html(body) do
      {:ok,
       %{
         title: title,
         body: body,
         summary: summary,
         area: area,
         version: version,
         media_url: media_url,
         media_alt: media_alt,
         media_caption: media_caption
       }}
    end
  end

  def parse_public(_), do: {:error, :malformed_yaml}

  defp split(markdown) do
    case String.split(markdown, "\n", parts: 2) do
      ["---", rest] -> split_end(rest, "")
      _ -> {:error, :malformed_yaml}
    end
  end

  defp split_end(<<"---\n", body::binary>>, _prefix), do: {:ok, "", body}
  defp split_end(<<"---\r\n", body::binary>>, _prefix), do: {:ok, "", body}

  defp split_end(rest, _prefix) do
    case Regex.run(~r/\A(.*?)(?:\n|\r\n)(---|\.\.\.)(?:\n|\r\n|\z)(.*)\z/s, rest,
           capture: :all_but_first
         ) do
      [yaml, _delimiter, body] -> {:ok, yaml, body}
      _ -> {:error, :malformed_yaml}
    end
  end

  defp read_yaml(yaml) do
    try do
      case YamlElixir.read_from_string(yaml, maps_as_keywords: true) do
        {:ok, pairs} when is_list(pairs) -> {:ok, pairs}
        {:ok, _} -> {:error, :nested_value}
        {:error, _reason} -> {:error, :malformed_yaml}
      end
    rescue
      _ -> {:error, :malformed_yaml}
    end
  end

  defp validate_keys(pairs) do
    if Enum.any?(pairs, fn pair -> not (is_tuple(pair) and tuple_size(pair) == 2) end) do
      {:error, :nested_value}
    else
      keys = Enum.map(pairs, fn {key, _value} -> key end)

      cond do
        Enum.any?(keys, &(normalize_key(&1) not in @metadata_keys)) ->
          {:error, :unknown_key}

        Enum.any?(@metadata_keys, fn key ->
          Enum.count(keys, &(normalize_key(&1) == key)) > 1
        end) or
            Enum.count(keys, &(normalize_key(&1) in ["media", "media_url"])) > 1 ->
          {:error, :duplicate_key}

        true ->
          :ok
      end
    end
  end

  defp title([]), do: {:error, :missing_title}

  defp title(pairs) do
    case find(pairs, "title") do
      nil ->
        {:error, :missing_title}

      {_key, value} when is_binary(value) ->
        if String.trim(value) == "", do: {:error, :invalid_title}, else: {:ok, value}

      {_key, value} when is_list(value) or is_map(value) ->
        {:error, :nested_value}

      _ ->
        {:error, :invalid_title}
    end
  end

  defp area(pairs) do
    case find(pairs, "area") do
      nil ->
        {:ok, nil}

      {_key, value} when is_binary(value) ->
        normalized = value |> String.trim() |> String.downcase()

        if normalized in @public_areas, do: {:ok, normalized}, else: {:error, :invalid_area}

      _ ->
        {:error, :invalid_area}
    end
  end

  defp media_url(pairs) do
    case find(pairs, "media_url") || find(pairs, "media") do
      nil ->
        {:ok, nil}

      {_key, value} when is_binary(value) ->
        value = String.trim(value)

        with true <- byte_size(value) <= 2048,
             %URI{scheme: scheme, host: host} <- URI.parse(value),
             true <- scheme in ["http", "https"] and is_binary(host) and host != "" do
          {:ok, value}
        else
          _ -> {:error, :invalid_media_url}
        end

      _ ->
        {:error, :invalid_media_url}
    end
  end

  defp optional_text(pairs, key, max_length, error) do
    case find(pairs, key) do
      nil ->
        {:ok, nil}

      {_key, value} when is_binary(value) ->
        value = String.trim(value)

        if value != "" and byte_size(value) <= max_length,
          do: {:ok, value},
          else: {:error, error}

      _ ->
        {:error, error}
    end
  end

  defp validate_media(nil, _alt), do: :ok
  defp validate_media(_url, alt) when is_binary(alt) and alt != "", do: :ok
  defp validate_media(_url, _alt), do: {:error, :invalid_media_alt}

  defp find(pairs, key),
    do: Enum.find(pairs, fn {pair_key, _} -> normalize_key(pair_key) == key end)

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(_key), do: nil

  defp reject_html(body) do
    if Regex.match?(~r/<\s*\/?\s*[A-Za-z][^>]*>/u, body) do
      {:error, :raw_html_forbidden}
    else
      :ok
    end
  end
end
