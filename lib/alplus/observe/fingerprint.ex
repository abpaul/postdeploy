defmodule Alplus.Observe.Fingerprint do
  @moduledoc """
  The stable, pure Observe issue-grouping algorithm.

  Keep this module independent from Ash and persistence. A change to its
  output creates new issue groups; golden-master cases therefore protect the
  wire-compatible implementation recovered from the previous service.
  """

  @max_frames 8
  @vendor_path_markers [
    "/node_modules/",
    "/dist/",
    "/vendor/",
    "/.pnpm/",
    "/@postdeploy/sdk",
    # Pre-rebrand scope: frames from `@alplus/sdk` clients still in the wild.
    "/@alplus/sdk"
  ]
  @internal_frame_files ["<anonymous>", "native code", "[native code]", "<unknown>"]
  @separator <<0>>

  @type stack_frame :: %{
          optional(:file) => String.t(),
          optional(:function) => String.t(),
          optional(:lineno) => integer(),
          optional(:colno) => integer(),
          optional(:in_app) => boolean()
        }

  @type subject :: %{
          required(:project_id) => String.t(),
          required(:environment) => String.t(),
          required(:level) => String.t(),
          optional(:custom_fingerprint) => [String.t()] | nil,
          optional(:exception_type) => String.t() | nil,
          optional(:exception_value) => String.t() | nil,
          optional(:message) => String.t() | nil,
          optional(:frames) => [stack_frame()] | nil
        }

  @type path :: :custom | :exception | :message

  @spec in_app_frame?(stack_frame()) :: boolean()
  def in_app_frame?(frame) do
    case Map.fetch(frame, :in_app) do
      {:ok, value} -> value
      :error -> inferred_in_app?(Map.get(frame, :file))
    end
  end

  @spec normalize_frame_path(String.t()) :: String.t()
  def normalize_frame_path(file) do
    file
    |> strip_origin()
    |> String.split(["#", "?"], parts: 2)
    |> hd()
  end

  @spec frame_signature([stack_frame()]) :: String.t() | nil
  def frame_signature(frames) do
    frames
    |> Enum.filter(&in_app_frame?/1)
    |> Enum.take(@max_frames)
    |> case do
      [] -> nil
      in_app -> Enum.map_join(in_app, "\n", &frame_signature_line/1)
    end
  end

  @spec normalize_message(String.t()) :: String.t()
  def normalize_message(message) do
    message
    |> replace(
      ~r/[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}/i,
      "<uuid>"
    )
    # Timestamp replacement deliberately precedes numbers. The previous
    # implementation documented that the written spec's reverse order makes
    # timestamp grouping unreachable.
    |> replace(
      ~r/\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?/,
      "<ts>"
    )
    |> replace(~r/\b[0-9a-f]{8,}\b/i, "<hex>")
    |> replace(~r/-?\d+(?:\.\d+)?/, "<num>")
    |> replace(~r/\s+/, " ")
    |> String.trim()
  end

  @spec build_input(subject()) :: %{path: path(), input: String.t()}
  def build_input(subject) do
    tail = @separator <> subject.project_id <> @separator <> subject.environment

    case Map.get(subject, :custom_fingerprint) do
      fingerprint when is_list(fingerprint) and fingerprint != [] ->
        %{path: :custom, input: Enum.join(fingerprint, @separator) <> tail}

      _ ->
        build_non_custom_input(subject, tail)
    end
  end

  @spec compute(subject()) :: %{fingerprint: String.t(), path: path()}
  def compute(subject) do
    %{path: path, input: input} = build_input(subject)
    digest = :crypto.hash(:sha256, input) |> Base.encode16(case: :lower)
    %{fingerprint: "sha256:" <> digest, path: path}
  end

  @spec exception_summary(String.t() | nil, String.t() | nil) :: String.t() | nil
  def exception_summary(type, value) when is_binary(type) and is_binary(value),
    do: type <> ": " <> value

  def exception_summary(type, _) when is_binary(type), do: type
  def exception_summary(_, value) when is_binary(value), do: value
  def exception_summary(_, _), do: nil

  @spec title(subject()) :: String.t()
  def title(subject) do
    case exception_summary(Map.get(subject, :exception_type), Map.get(subject, :exception_value)) do
      nil ->
        case Map.get(subject, :message) do
          message when is_binary(message) ->
            case String.trim(message) do
              "" -> "Unknown error"
              trimmed -> trimmed
            end

          _ ->
            "Unknown error"
        end

      summary ->
        summary
    end
  end

  @spec culprit([stack_frame()] | nil) :: String.t() | nil
  def culprit(nil), do: nil

  def culprit(frames) do
    case Enum.find(frames, &in_app_frame?/1) do
      nil ->
        nil

      frame ->
        function = present_or_anonymous(Map.get(frame, :function))

        case Map.get(frame, :file) do
          nil -> function
          file -> normalize_frame_path(file) <> ":" <> function
        end
    end
  end

  defp build_non_custom_input(subject, tail) do
    case Map.get(subject, :frames) do
      frames when is_list(frames) ->
        case frame_signature(frames) do
          nil ->
            message_input(subject, tail)

          signature ->
            %{
              path: :exception,
              input: (Map.get(subject, :exception_type) || "") <> @separator <> signature <> tail
            }
        end

      _ ->
        message_input(subject, tail)
    end
  end

  defp message_input(subject, tail) do
    message =
      Map.get(subject, :message) ||
        exception_summary(Map.get(subject, :exception_type), Map.get(subject, :exception_value)) ||
        ""

    %{path: :message, input: subject.level <> @separator <> normalize_message(message) <> tail}
  end

  defp inferred_in_app?(file) when not is_binary(file) or file == "", do: false

  defp inferred_in_app?(file) do
    file not in @internal_frame_files and
      not Enum.any?(@vendor_path_markers, &String.contains?(file, &1)) and
      not bare_specifier?(file)
  end

  defp bare_specifier?(file) do
    String.starts_with?(file, ["node:", "webpack://", "internal/"]) or
      (not String.contains?(file, "/") and not String.contains?(file, "\\"))
  end

  defp strip_origin(file) do
    case Regex.run(~r/^[a-z][a-z0-9+.-]*:\/\/[^\/]*(\/.*)?$/i, file) do
      [_, path] when is_binary(path) -> path
      [_] -> "/"
      _ -> file
    end
  end

  defp replace(value, regex, replacement), do: Regex.replace(regex, value, replacement)

  defp frame_signature_line(frame) do
    function = present_or_anonymous(Map.get(frame, :function))
    file = Map.get(frame, :file, "")
    function <> "@" <> normalize_frame_path(file)
  end

  defp present_or_anonymous(function) when is_binary(function) and byte_size(function) > 0,
    do: function

  defp present_or_anonymous(_), do: "<anonymous>"
end
