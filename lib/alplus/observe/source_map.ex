defmodule Alplus.Observe.SourceMap do
  @moduledoc """
  A pure-Elixir source map (revision 3) decoder and position lookup.

  Implemented in-repo instead of pulling a dependency: the format is one
  JSON object plus base64-VLQ `mappings`, and the decode below is ~100
  lines — smaller than the supply-chain surface of any wrapper package.

  `parse/1` decodes the JSON and the full mappings string once; cache the
  result (see `Alplus.Observe.Symbolicator`) — decoding is the expensive
  part, `lookup/3` afterwards is a binary search.

  Positions follow the spec: generated and original lines are 0-based in
  the mappings, columns 0-based. `lookup/3` takes the 1-based line/column a
  JS `Error` stack reports and converts internally.
  """

  @base64_chars ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  @char_values Map.new(Enum.with_index(@base64_chars))

  @type parsed :: %{
          sources: tuple(),
          names: tuple(),
          sources_content: tuple() | nil,
          # generated line (0-based) => segments sorted by generated column,
          # each {gen_col, source_index, orig_line, orig_col, name_index | nil}
          lines: %{non_neg_integer() => tuple()}
        }

  @spec parse(binary()) :: {:ok, parsed()} | {:error, :invalid_source_map}
  def parse(raw) when is_binary(raw) do
    with {:ok, %{"version" => 3, "mappings" => mappings, "sources" => sources} = map}
         when is_binary(mappings) and is_list(sources) <- Jason.decode(raw) do
      {:ok,
       %{
         sources: List.to_tuple(sources),
         names: map |> Map.get("names", []) |> List.to_tuple(),
         sources_content: sources_content(map),
         lines: decode_mappings(mappings)
       }}
    else
      _ -> {:error, :invalid_source_map}
    end
  rescue
    _ -> {:error, :invalid_source_map}
  end

  @doc """
  Original position for a 1-based generated `line`/`column`. Picks the
  segment with the greatest generated column not past `column` on that
  line (the spec's lookup rule). Returns `:error` when the map holds no
  segment for the line.
  """
  @spec lookup(parsed(), pos_integer(), pos_integer()) ::
          {:ok,
           %{
             source: String.t() | nil,
             line: pos_integer(),
             column: pos_integer(),
             name: String.t() | nil
           }}
          | :error
  def lookup(parsed, line, column) when line >= 1 and column >= 1 do
    with {:ok, segments} <- Map.fetch(parsed.lines, line - 1),
         {:ok, {_gen_col, source_index, orig_line, orig_col, name_index}} <-
           find_segment(segments, column - 1) do
      {:ok,
       %{
         source: elem_or_nil(parsed.sources, source_index),
         line: orig_line + 1,
         column: orig_col + 1,
         name: name_index && elem_or_nil(parsed.names, name_index)
       }}
    else
      _ -> :error
    end
  end

  def lookup(_parsed, _line, _column), do: :error

  @doc """
  The original source text around a (1-based) original line, from the
  map's inline `sourcesContent`. Returns `:error` when the map carries no
  content for that source (an external-content map still symbolicates,
  it just renders no code block).
  """
  @spec source_context(parsed(), String.t() | nil, pos_integer(), pos_integer()) ::
          {:ok,
           %{pre_context: [String.t()], context_line: String.t(), post_context: [String.t()]}}
          | :error
  def source_context(parsed, source, line, context_lines)
      when is_binary(source) and line >= 1 do
    with content_by_source when not is_nil(content_by_source) <- parsed.sources_content,
         {:ok, content} when is_binary(content) <- Map.fetch(content_by_source, source) do
      # Keep the unneeded suffix in one part beyond the context window.
      lines = String.split(content, ["\r\n", "\n"], parts: line + context_lines + 1)
      index = line - 1

      if index < length(lines) do
        {:ok,
         %{
           pre_context:
             lines
             |> Enum.slice(max(index - context_lines, 0), min(index, context_lines))
             |> Enum.map(&cap_line/1),
           context_line: lines |> Enum.at(index) |> cap_line(),
           post_context: lines |> Enum.slice(index + 1, context_lines) |> Enum.map(&cap_line/1)
         }}
      else
        :error
      end
    else
      _ -> :error
    end
  end

  def source_context(_parsed, _source, _line, _context_lines), do: :error

  # Mirrors the Ruby SDK's MAX_SOURCE_LINE_CHARS: one absurdly long
  # (minified/generated) line is truncated, not shipped whole.
  defp cap_line(line), do: String.slice(line, 0, 500)

  defp sources_content(%{"sourcesContent" => content} = map) when is_list(content) do
    map["sources"]
    |> Enum.zip(content)
    |> Enum.reject(fn {_source, text} -> is_nil(text) end)
    |> case do
      [] -> nil
      pairs -> Map.new(pairs)
    end
  end

  defp sources_content(_map), do: nil

  defp elem_or_nil(_tuple, nil), do: nil

  defp elem_or_nil(tuple, index) when index >= 0 and index < tuple_size(tuple),
    do: elem(tuple, index)

  defp elem_or_nil(_tuple, _index), do: nil

  # Decodes the `mappings` string. Per spec: lines split on `;`, segments
  # on `,`. The generated column resets each line; source index, original
  # line, original column, and name index accumulate across the whole map.
  defp decode_mappings(mappings) do
    mappings
    |> String.split(";")
    |> Enum.with_index()
    |> Enum.reduce({%{}, {0, 0, 0, 0}}, fn {line, line_index}, {acc, carry} ->
      {segments, carry} = decode_line(line, carry)

      case segments do
        [] -> {acc, carry}
        _ -> {Map.put(acc, line_index, List.to_tuple(segments)), carry}
      end
    end)
    |> elem(0)
  end

  defp decode_line("", carry), do: {[], carry}

  defp decode_line(line, {src, orig_line, orig_col, name}) do
    line
    |> String.split(",")
    |> Enum.reduce({[], 0, {src, orig_line, orig_col, name}}, fn segment,
                                                                 {segments, gen_col, carry} ->
      case decode_segment(segment, gen_col, carry) do
        {:ok, decoded, gen_col, carry} -> {[decoded | segments], gen_col, carry}
        :skip -> {segments, gen_col, carry}
      end
    end)
    |> then(fn {segments, _gen_col, carry} -> {Enum.reverse(segments), carry} end)
  end

  defp decode_segment(segment, gen_col, {src, orig_line, orig_col, name} = carry) do
    case decode_vlq(segment) do
      [col_delta] ->
        # A 1-field segment maps a generated range to no original position;
        # it still advances the generated column for later segments.
        {:ok, {gen_col + col_delta, nil, 0, 0, nil}, gen_col + col_delta, carry}

      [col_delta, src_delta, line_delta, col2_delta | rest] ->
        gen_col = gen_col + col_delta
        src = src + src_delta
        orig_line = orig_line + line_delta
        orig_col = orig_col + col2_delta

        name =
          case rest do
            [name_delta] -> name + name_delta
            _ -> name
          end

        name_index =
          case rest do
            [_name_delta] -> name
            _ -> nil
          end

        {:ok, {gen_col, src, orig_line, orig_col, name_index}, gen_col,
         {src, orig_line, orig_col, name}}

      _ ->
        :skip
    end
  end

  # Base64 VLQ: 6 bits per char, bit 5 (value 32) continues, and the first
  # value's bit 0 carries the sign.
  defp decode_vlq(segment) do
    segment
    |> String.to_charlist()
    |> Enum.reduce_while({[], 0, 0}, fn char, {values, shift, accumulated} ->
      case Map.fetch(@char_values, char) do
        {:ok, digit} ->
          accumulated = accumulated + Bitwise.bsl(Bitwise.band(digit, 31), shift)

          if Bitwise.band(digit, 32) == 32 do
            {:cont, {values, shift + 5, accumulated}}
          else
            {:cont, {[from_vlq_signed(accumulated) | values], 0, 0}}
          end

        :error ->
          {:halt, :invalid}
      end
    end)
    |> case do
      {values, 0, 0} -> Enum.reverse(values)
      _ -> :invalid
    end
  end

  defp from_vlq_signed(value) do
    magnitude = Bitwise.bsr(value, 1)
    if Bitwise.band(value, 1) == 1, do: -magnitude, else: magnitude
  end

  # Binary search over the line's segment tuple: greatest generated column
  # not exceeding `column`, skipping no-source segments.
  defp find_segment(segments, column) do
    find_segment(segments, column, 0, tuple_size(segments) - 1, :error)
  end

  defp find_segment(_segments, _column, low, high, best) when low > high, do: unwrap_best(best)

  defp find_segment(segments, column, low, high, best) do
    mid = div(low + high, 2)
    {gen_col, _src, _line, _col, _name} = segment = elem(segments, mid)

    if gen_col <= column do
      find_segment(segments, column, mid + 1, high, {:ok, segment})
    else
      find_segment(segments, column, low, mid - 1, best)
    end
  end

  defp unwrap_best({:ok, {_gen, nil, _line, _col, _name}}), do: :error
  defp unwrap_best({:ok, _segment} = ok), do: ok
  defp unwrap_best(:error), do: :error
end
