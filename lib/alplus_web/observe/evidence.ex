defmodule AlplusWeb.Observe.Evidence do
  @moduledoc """
  Presentation for one Observe issue's evidence.

  Callers pass a normalized `Alplus.Observe.Occurrence`. This module owns
  stack labels, cause-frame dedupe, breadcrumb split, occurrence columns,
  and member display names. The LiveView keeps assign, events, and layout.
  """

  use AlplusWeb, :html

  alias Alplus.Observe.Occurrence

  @doc """
  Columns for Recent occurrences: Received plus fields that change.

  User, Release, and SDK disappear when every row carries the same value.
  A single occurrence therefore shows only Received.
  """
  @spec occurrence_columns([Occurrence.t()]) :: [:received | :user | :release | :sdk]
  def occurrence_columns(occurrences) when is_list(occurrences) do
    [:received | Enum.filter([:user, :release, :sdk], &varies?(occurrences, &1))]
  end

  @spec unique_cause_frames(map(), [map()] | nil) :: [map()]
  def unique_cause_frames(cause, parent_frames) do
    cause_frames = List.wrap(cause[:frames])
    parent_frames = List.wrap(parent_frames)

    if cause_frames != [] and new_stack_sites?(cause_frames, parent_frames) do
      cause_frames
    else
      []
    end
  end

  @spec before_crumbs(Occurrence.t()) :: [map()]
  def before_crumbs(%Occurrence{breadcrumbs: crumbs, message: message}) when is_list(crumbs) do
    crumbs
    |> Enum.reject(&(after_error?(&1) or redundant_event_crumb?(&1, message)))
  end

  def before_crumbs(_occurrence), do: []

  @spec after_crumbs(Occurrence.t()) :: [map()]
  def after_crumbs(%Occurrence{breadcrumbs: crumbs, message: message}) when is_list(crumbs) do
    crumbs
    |> Enum.filter(&after_error?/1)
    |> Enum.reject(&redundant_event_crumb?(&1, message))
  end

  def after_crumbs(_occurrence), do: []

  defp redundant_event_crumb?(%{message: crumb_message}, event_message),
    do: is_binary(event_message) && crumb_message == event_message

  defp redundant_event_crumb?(_crumb, _event_message), do: false

  @spec unhandled?(Occurrence.t() | nil) :: boolean()
  def unhandled?(nil), do: false
  def unhandled?(%Occurrence{mechanism: mechanism}), do: mechanism not in [nil, "generic"]

  @spec occurrence_context(Occurrence.t(), map()) :: map() | nil
  def occurrence_context(%Occurrence{} = occurrence, issue) do
    non_empty_map(occurrence.context) || non_empty_map(Map.get(issue, :context_summary))
  end

  @spec extra_context(Occurrence.t(), map()) :: map() | nil
  def extra_context(occurrence, issue) do
    case occurrence_context(occurrence, issue) do
      nil -> nil
      context -> non_empty_map(Map.delete(context, "request"))
    end
  end

  @spec request_context(Occurrence.t() | nil) :: map() | nil
  def request_context(%Occurrence{context: %{"request" => request}}) when is_map(request),
    do: request

  def request_context(_occurrence), do: nil

  @spec highlight_items(Occurrence.t() | nil) :: [
          %{label: String.t(), value: String.t()}
        ]
  def highlight_items(occurrence) do
    context = (occurrence && occurrence.context) || %{}

    # Environment and release live on Details. This strip is the
    # event's client facts only.
    [
      highlight_item("OS", context_name(context, "os")),
      highlight_item("Browser", context_name(context, "browser")),
      highlight_item("Runtime", context_name(context, "runtime"))
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Request headers, query, and params as labelled rows.

  Method, path, host, and url stay on the Request lead line. Values
  flatten to strings. Nested maps encode as JSON.
  """
  @spec request_detail_items(map() | nil) :: [%{label: String.t(), value: String.t()}]
  def request_detail_items(nil), do: []

  def request_detail_items(request) when is_map(request) do
    query_items =
      request
      |> request_value(["query", "query_params", :query, :query_params])
      |> map_detail_items("Query")

    param_items =
      request
      |> request_value(["params", :params])
      |> map_detail_items("Param")

    header_items =
      request
      |> request_value(["headers", :headers])
      |> map_detail_items(nil)

    query_string_items =
      case request_value(request, ["query_string", :query_string]) do
        value when is_binary(value) and value != "" ->
          [%{label: "Query", value: value}]

        _ ->
          []
      end

    query_items ++ query_string_items ++ param_items ++ header_items
  end

  @spec in_app_frame?(map()) :: boolean()
  def in_app_frame?(frame) when is_map(frame) do
    Alplus.Observe.Fingerprint.in_app_frame?(frame)
  end

  @spec visible_frames([map()] | nil, keyword()) :: [map()]
  def visible_frames(frames, opts \\ []) do
    frames = List.wrap(frames)
    in_app_only? = Keyword.get(opts, :in_app_only, false)

    in_app = Enum.filter(frames, &in_app_frame?/1)

    shown =
      cond do
        not in_app_only? ->
          frames

        in_app != [] ->
          in_app

        true ->
          # A stack with no in-app mark would go blank. Keep the frames
          # and let `stack_summary/2` say none were marked.
          frames
      end

    if Keyword.get(opts, :order) == :newest_first do
      Enum.reverse(shown)
    else
      shown
    end
  end

  @spec stack_summary([map()] | nil, keyword()) :: String.t()
  def stack_summary(frames, opts \\ []) do
    frames = List.wrap(frames)
    shown = visible_frames(frames, opts)
    in_app_count = Enum.count(frames, &in_app_frame?/1)

    order =
      if Keyword.get(opts, :order) == :newest_first, do: "callers first", else: "exception first"

    view = if Keyword.get(opts, :view) == :raw, do: "raw dump", else: "source view"

    cond do
      Keyword.get(opts, :in_app_only, false) and in_app_count == 0 ->
        "No frames marked in-app. Showing all #{length(frames)}, #{order}, #{view}."

      Keyword.get(opts, :in_app_only, false) ->
        "Showing #{length(shown)} in-app of #{length(frames)}, #{order}, #{view}."

      true ->
        "Showing #{length(shown)} frames (#{in_app_count} in-app), #{order}, #{view}."
    end
  end

  @spec raw_stack([map()] | nil, keyword()) :: String.t()
  def raw_stack(frames, opts \\ []) do
    header =
      case {Keyword.get(opts, :type), Keyword.get(opts, :value)} do
        {type, value} when is_binary(type) and is_binary(value) -> "#{type}: #{value}\n\n"
        {type, _} when is_binary(type) -> "#{type}\n\n"
        _ -> ""
      end

    body =
      frames
      |> visible_frames(opts)
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {frame, i} -> "#{i}  #{frame_label(frame)}" end)

    header <> body
  end

  @spec copy_for_ai(map(), Occurrence.t() | nil) :: String.t()
  def copy_for_ai(issue, occurrence) do
    [
      "# #{issue.title}",
      "",
      "Culprit: #{issue.culprit || "unknown"}",
      "Environment: #{issue.environment || "not set"}",
      "Status: #{issue.status}",
      "Events: #{issue.event_count}",
      occurrence && occurrence.exception_type &&
        "Exception: #{occurrence.exception_type}: #{occurrence.exception_value}",
      occurrence && occurrence.message && "Message: #{occurrence.message}",
      "",
      "## Stack",
      occurrence && raw_stack(occurrence.frames, order: :newest_first),
      "",
      request_markdown(occurrence),
      "",
      "## Tags",
      occurrence && occurrence.tags &&
        Enum.map_join(occurrence.tags, "\n", fn {k, v} -> "- #{k}: #{v}" end)
    ]
    |> Enum.reject(&(&1 == false or is_nil(&1)))
    |> Enum.join("\n")
    |> String.trim()
  end

  @spec raw_event(Occurrence.t()) :: String.t()
  def raw_event(%Occurrence{} = occurrence) do
    occurrence
    |> Map.from_struct()
    |> Map.drop([:__struct__])
    |> Jason.encode!(pretty: true)
  end

  @spec relative_time(DateTime.t() | NaiveDateTime.t(), DateTime.t()) :: String.t()
  def relative_time(datetime, now \\ DateTime.utc_now())

  def relative_time(%NaiveDateTime{} = datetime, now) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> relative_time(now)
  end

  def relative_time(%DateTime{} = datetime, now) do
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> ago(div(diff, 60), "minute")
      diff < 86_400 -> ago(div(diff, 3600), "hour")
      diff < 86_400 * 30 -> ago(div(diff, 86_400), "day")
      true -> ago(div(diff, 86_400 * 30), "month")
    end
  end

  defp ago(1, unit), do: "1 #{unit} ago"
  defp ago(count, unit), do: "#{count} #{unit}s ago"

  def adjacent_event_ids(occurrences, selected_id) when is_list(occurrences) do
    ids = Enum.map(occurrences, & &1.event_id)
    index = Enum.find_index(ids, &(&1 == selected_id))

    cond do
      is_nil(index) ->
        {nil, nil}

      true ->
        older = if index < length(ids) - 1, do: Enum.at(ids, index + 1)
        newer = if index > 0, do: Enum.at(ids, index - 1)
        {older, newer}
    end
  end

  @spec member_display_name(map() | nil) :: String.t()
  def member_display_name(%{name: name}) when is_binary(name) and name != "", do: name

  def member_display_name(%{email: email}) when not is_nil(email) do
    email
    |> to_string()
    |> String.split("@", parts: 2)
    |> hd()
    |> String.split("+", parts: 2)
    |> hd()
    |> String.replace(~r/[._-]+/, " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def member_display_name(_user), do: "Unnamed"

  @spec assignee_label([%{id: term(), label: String.t()}], String.t() | nil) :: String.t()
  def assignee_label(_members, nil), do: "Unassigned"

  def assignee_label(members, assignee_id) do
    case Enum.find(members, &(&1.id == assignee_id)) do
      nil -> "Unassigned"
      member -> member.label
    end
  end

  attr :frames, :list, required: true

  def stack_frames(assigns) do
    ~H"""
    <ol class="overflow-x-auto rounded-control bg-surface-inverse">
      <li
        :for={frame <- @frames}
        class={[
          "border-t border-border-subtle px-4 py-2 first:border-t-0",
          library_frame?(frame) && "text-text-inverse-muted",
          not library_frame?(frame) && "text-text-inverse"
        ]}
      >
        <p class="font-mono text-data">
          {frame_label(frame)}
        </p>
        <.source_context frame={frame} />
      </li>
    </ol>
    """
  end

  attr :crumb, :map, required: true
  attr :occurred_at, :any, required: true

  def breadcrumb_line(assigns) do
    assigns = assign(assigns, :offset, crumb_offset(assigns.crumb, assigns.occurred_at))

    ~H"""
    <span
      :if={@offset}
      class="inline-block w-14 text-right text-data tabular-nums text-text-tertiary"
      title={@crumb[:ts]}
    >
      {@offset}
    </span>
    <span :if={@crumb[:level]} class="ml-2 text-data text-text-tertiary">{@crumb[:level]}</span>
    <span class="ml-2 text-data text-text-secondary">[{@crumb[:category]}]</span>
    <span class="ml-2 text-pretty text-data text-text-primary">{@crumb[:message]}</span>
    <span :if={crumb_data(@crumb)} class="ml-2 text-data text-text-tertiary">({crumb_data(@crumb)})</span>
    """
  end

  attr :frame, :map, required: true

  defp source_context(%{frame: frame} = assigns) do
    cond do
      library_frame?(frame) ->
        ~H""

      is_nil(frame[:context_line]) ->
        ~H""

      true ->
        assigns = assign(assigns, :lines, numbered_context_lines(frame))

        ~H"""
        <pre
          phx-no-curly-interpolation
          class="mt-1.5 overflow-x-auto p-2 font-mono text-data text-text-inverse-muted"
        ><%= for {lineno, line, current?} <- @lines do %><span class={current? && "block bg-surface-inverse-raised font-medium text-text-inverse" || "block"}><%= gutter(lineno) %><%= line %></span><% end %></pre>
        """
    end
  end

  defp varies?(occurrences, :user) do
    occurrences
    |> Enum.map(&{&1.user_id, &1.user_email})
    |> distinct?()
  end

  defp varies?(occurrences, :release) do
    occurrences |> Enum.map(& &1.release) |> distinct?()
  end

  defp varies?(occurrences, :sdk) do
    occurrences |> Enum.map(&{&1.sdk_name, &1.sdk_version}) |> distinct?()
  end

  defp distinct?(values), do: values |> Enum.uniq() |> length() > 1

  defp new_stack_sites?(cause_frames, parent_frames) do
    parent_sites = MapSet.new(parent_frames, &frame_site/1)

    Enum.any?(cause_frames, fn frame ->
      not MapSet.member?(parent_sites, frame_site(frame))
    end)
  end

  defp frame_site(frame), do: {frame[:function], frame[:file]}

  defp library_frame?(frame), do: frame[:in_app] == false

  defp frame_label(frame) do
    function = frame[:function] || "<anonymous>"
    file = frame[:file]

    location =
      case {file, frame[:lineno], frame[:colno]} do
        {nil, _, _} -> nil
        {file, nil, _} -> file
        {file, lineno, nil} -> "#{file}:#{lineno}"
        {file, lineno, colno} -> "#{file}:#{lineno}:#{colno}"
      end

    if location, do: "#{function} @ #{location}", else: function
  end

  defp numbered_context_lines(frame) do
    pre = List.wrap(frame[:pre_context])
    post = List.wrap(frame[:post_context])
    lineno = frame[:lineno]

    pre_numbered =
      case lineno do
        nil ->
          Enum.map(pre, &{nil, &1, false})

        n ->
          pre
          |> Enum.with_index(n - length(pre))
          |> Enum.map(fn {line, i} -> {i, line, false} end)
      end

    post_numbered =
      case lineno do
        nil -> Enum.map(post, &{nil, &1, false})
        n -> post |> Enum.with_index(n + 1) |> Enum.map(fn {line, i} -> {i, line, false} end)
      end

    pre_numbered ++ [{lineno, frame[:context_line], true}] ++ post_numbered
  end

  defp gutter(nil), do: "     | "
  defp gutter(lineno), do: String.pad_leading(Integer.to_string(lineno), 5) <> " | "

  defp after_error?(%{data: data}) when is_map(data) do
    Map.get(data, "after_error") == true or Map.get(data, :after_error) == true
  end

  defp after_error?(_crumb), do: false

  defp crumb_offset(crumb, %DateTime{} = occurred_at) do
    with ts when is_binary(ts) <- crumb[:ts],
         {:ok, crumb_at, _offset} <- DateTime.from_iso8601(ts) do
      format_offset(DateTime.diff(crumb_at, occurred_at, :millisecond))
    else
      _ -> nil
    end
  end

  defp crumb_offset(_crumb, _occurred_at), do: nil

  defp format_offset(diff_ms) when abs(diff_ms) < 60_000 do
    sign = if diff_ms < 0, do: "-", else: "+"
    sign <> :erlang.float_to_binary(abs(diff_ms) / 1000, decimals: 1) <> "s"
  end

  defp format_offset(diff_ms) do
    sign = if diff_ms < 0, do: "-", else: "+"
    total_seconds = div(abs(diff_ms), 1000)
    "#{sign}#{div(total_seconds, 60)}m #{rem(total_seconds, 60)}s"
  end

  defp crumb_data(crumb) do
    case crumb[:data] do
      data when is_map(data) ->
        rest =
          data
          |> Map.delete("after_error")
          |> Map.delete(:after_error)

        case rest do
          empty when map_size(empty) == 0 ->
            nil

          rest ->
            Enum.map_join(rest, ", ", fn {key, value} ->
              "#{key}: #{format_crumb_value(value)}"
            end)
        end

      _ ->
        nil
    end
  end

  defp format_crumb_value(value) when is_binary(value), do: value
  defp format_crumb_value(value) when is_number(value), do: to_string(value)
  defp format_crumb_value(value), do: inspect(value)

  defp non_empty_map(map) when is_map(map) and map_size(map) > 0, do: map
  defp non_empty_map(_), do: nil

  defp highlight_item(_label, nil), do: nil
  defp highlight_item(_label, ""), do: nil
  defp highlight_item(label, value), do: %{label: label, value: to_string(value)}

  defp request_value(request, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(request, key) do
        nil -> nil
        value -> value
      end
    end)
  end

  defp map_detail_items(map, prefix) when is_map(map) and map_size(map) > 0 do
    map
    |> Enum.sort_by(fn {key, _} -> to_string(key) end)
    |> Enum.map(fn {key, value} ->
      label =
        case prefix do
          nil -> to_string(key)
          prefix -> "#{prefix} #{key}"
        end

      %{label: label, value: format_request_value(value)}
    end)
  end

  defp map_detail_items(_value, _prefix), do: []

  defp format_request_value(value) when is_binary(value), do: value
  defp format_request_value(value) when is_number(value), do: to_string(value)
  defp format_request_value(true), do: "true"
  defp format_request_value(false), do: "false"

  defp format_request_value(value) when is_list(value) do
    Enum.map_join(value, ", ", &format_request_value/1)
  end

  defp format_request_value(value) when is_map(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value)
    end
  end

  defp format_request_value(value), do: inspect(value)

  defp context_name(context, key) when is_map(context) do
    case Map.get(context, key) do
      %{"name" => name} -> name
      name when is_binary(name) -> name
      _ -> nil
    end
  end

  defp context_name(_context, _key), do: nil

  defp request_markdown(nil), do: nil

  defp request_markdown(occurrence) do
    case request_context(occurrence) do
      nil ->
        nil

      request ->
        method = request["method"] || request[:method] || "GET"
        path = request["path"] || request[:path] || request["url"] || request[:url]
        "## Request\n#{method} #{path}"
    end
  end
end
