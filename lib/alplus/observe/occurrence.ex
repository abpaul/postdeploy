defmodule Alplus.Observe.Occurrence do
  @moduledoc """
  One `error_events` row as the Observe evidence interface.

  Built only by `Alplus.Observe.IssueEvidence`. Frames, causes, and
  breadcrumbs use atom keys. Callers never see the JSON string/atom mix
  stored on the row.
  """

  @type frame :: %{optional(atom()) => term()}
  @type cause :: %{optional(atom()) => term()}
  @type breadcrumb :: %{optional(atom()) => term()}

  @type t :: %__MODULE__{
          event_id: String.t(),
          received_at: DateTime.t() | NaiveDateTime.t(),
          occurred_at: DateTime.t() | NaiveDateTime.t() | nil,
          level: String.t() | nil,
          message: String.t() | nil,
          exception_type: String.t() | nil,
          exception_value: String.t() | nil,
          frames: [frame()] | nil,
          context: map() | nil,
          tags: map() | nil,
          breadcrumbs: [breadcrumb()] | nil,
          release: String.t() | nil,
          sdk_name: String.t() | nil,
          sdk_version: String.t() | nil,
          payload_s3_key: String.t() | nil,
          user_id: String.t() | nil,
          user_email: String.t() | nil,
          mechanism: String.t() | nil,
          causes: [cause()] | nil
        }

  @behaviour Access

  defstruct [
    :event_id,
    :received_at,
    :occurred_at,
    :level,
    :message,
    :exception_type,
    :exception_value,
    :frames,
    :context,
    :tags,
    :breadcrumbs,
    :release,
    :sdk_name,
    :sdk_version,
    :payload_s3_key,
    :user_id,
    :user_email,
    :mechanism,
    :causes
  ]

  @frame_keys ~w(file function lineno colno in_app pre_context context_line post_context)
  @cause_keys ~w(type value frames)
  @crumb_keys ~w(category message level ts data)

  @impl Access
  def fetch(%__MODULE__{} = occurrence, key) when is_atom(key), do: Map.fetch(occurrence, key)

  @impl Access
  def get_and_update(%__MODULE__{} = occurrence, key, fun) when is_atom(key) do
    Map.get_and_update(occurrence, key, fun)
  end

  @impl Access
  def pop(%__MODULE__{} = occurrence, key) when is_atom(key), do: Map.pop(occurrence, key)

  @doc "Builds an occurrence from an `IssueEvidence` column zip."
  @spec from_row(%{atom() => term()}) :: t()
  def from_row(row) when is_map(row) do
    %__MODULE__{
      event_id: row.event_id,
      received_at: row.received_at,
      occurred_at: row.occurred_at,
      level: row.level,
      message: row.message,
      exception_type: row.exception_type,
      exception_value: row.exception_value,
      frames: normalize_frames(row.frames),
      context: row.context,
      tags: row.tags,
      breadcrumbs: normalize_breadcrumbs(row.breadcrumbs),
      release: row.release,
      sdk_name: row.sdk_name,
      sdk_version: row.sdk_version,
      payload_s3_key: row.payload_s3_key,
      user_id: row.user_id,
      user_email: row.user_email,
      mechanism: row.mechanism,
      causes: normalize_causes(row.causes)
    }
  end

  defp normalize_frames(frames) when is_list(frames), do: Enum.map(frames, &normalize_frame/1)
  defp normalize_frames(other), do: other

  defp normalize_frame(frame) when is_map(frame) do
    take_known(frame, @frame_keys)
  end

  defp normalize_frame(other), do: other

  defp normalize_causes(causes) when is_list(causes), do: Enum.map(causes, &normalize_cause/1)
  defp normalize_causes(other), do: other

  defp normalize_cause(cause) when is_map(cause) do
    cause
    |> take_known(@cause_keys)
    |> Map.update(:frames, nil, &normalize_frames/1)
  end

  defp normalize_cause(other), do: other

  defp normalize_breadcrumbs(crumbs) when is_list(crumbs),
    do: Enum.map(crumbs, &normalize_breadcrumb/1)

  defp normalize_breadcrumbs(other), do: other

  defp normalize_breadcrumb(crumb) when is_map(crumb), do: take_known(crumb, @crumb_keys)
  defp normalize_breadcrumb(other), do: other

  defp take_known(map, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case fetch_either(map, key) do
        {:ok, value} -> Map.put(acc, String.to_existing_atom(key), value)
        :error -> acc
      end
    end)
  end

  defp fetch_either(map, string_key) do
    atom = String.to_existing_atom(string_key)

    case Map.fetch(map, string_key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, atom)
    end
  end
end
